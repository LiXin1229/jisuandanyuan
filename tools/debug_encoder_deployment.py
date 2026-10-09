"""Programmed stage-1 image: load RGB frames and compare all 384 final tiles.

Official Efinity JTAG API; artifacts stay in this workspace, never in pe10_10.
"""
from pathlib import Path
import argparse,hashlib,json,os,sys,time,zlib
from datetime import datetime,timezone

ROOT=Path(__file__).resolve().parents[1]
EFX=Path(os.environ.get('EFINITY_HOME',r'D:\Efinity\2026.1'))
sys.path.insert(0,str(EFX/'debugger/bin'))
from efx_dbg.define import DebugProfileBuilder
from efx_dbg.jtag import JtagManager
from pyftdi.bits import BitSequence

class Board:
 def __init__(self,project,url,freq,signature=0xe311):
  self.manager=JtagManager();self.jtag=self.manager.config_jtag(url=url,tap='efx_ti',user='USER1',freq=freq)
  # Efinity uses PyFtdi's 16 ms default. Small acknowledged VIO transfers
  # benefit from its supported 1 ms USB latency setting; restore on close.
  with self.jtag.get_engine() as engine:
   self.ftdi=engine._engine_provider._ctrl.ftdi
   self.previous_latency=self.ftdi.get_latency_timer();self.ftdi.set_latency_timer(1)
  profile,_=DebugProfileBuilder.from_file(str(project/'debug_profile.json'))
  self.debug=self.manager.config_debug(self.jtag,profile);self.manager.validate_debug_cores(self.debug)
  s=self.read()
  if s['status']>>16!=signature:raise RuntimeError(f'Unexpected image: {s["status"]:08x}, expected {signature:04x}')
  self.toggle=(s['status']>>8)&1;self.payload=0
  print(f'STAGE{2 if signature in (0xe312,0xe313) else 1}_JTAG_CONNECTED',hex(s['status']),flush=True)
 def read(self):
  v=[int(x) for x in self.manager.read_vio(self.debug,'vio0')]
  return dict(status=v[0],cycles=v[1],busy_cycles=v[2],first_output=v[3],frames=v[4]>>16,
   chunks=v[4]&65535,frame_id=v[5],calibration=v[6],data=sum(x<<(200*i) for i,x in enumerate(v[7:11])),
   command_wait_cycles=v[11],data_wait_cycles=v[12],input_checksum=v[13])
 def command(self,op,arg=0,payload=None):
  if payload is not None:self.payload=payload
  self.toggle^=1
  self.manager.set_vio_probe_out(self.debug,'vio0',[BitSequence((self.toggle<<31)|(op<<28)|arg,length=32),
   BitSequence(self.payload&((1<<256)-1),length=256),BitSequence(self.payload>>256,length=256)])
  self.manager.write_vio(self.debug,'vio0')
 def wait(self,complete=False,timeout=30):
  deadline=time.monotonic()+timeout
  while True:
   s=self.read()
   if s['status']&0x3c00:raise RuntimeError(f'Board fault {s}')
   if (s['status']>>8)&1==self.toggle and (not complete or not s['status']&(1<<9)):return s
   if time.monotonic()>deadline:raise TimeoutError(f'Mailbox timeout {s}')
 def close(self):
  self.ftdi.set_latency_timer(self.previous_latency)
  self.manager.unconfig_jtag(self.jtag)

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--project',type=Path);ap.add_argument('--url',required=True)
 ap.add_argument('--frames',type=int,default=2,choices=[1,2,4]);ap.add_argument('--frequency',type=float,default=3e6)
 ap.add_argument('--connect-only',action='store_true');ap.add_argument('--verify-ddr',action='store_true');args=ap.parse_args()
 project=args.project or Path((ROOT/'build/stage1/staging_path.txt').read_text().strip())
 os.environ.setdefault('EFINITY_USER_DIR',str(project/'vendor_user'))
 out=ROOT/'build/stage1';out.mkdir(exist_ok=True)
 board=Board(project,args.url,args.frequency);reports=[];begin=time.monotonic()
 try:
  board.command(5);state=board.wait()
  if args.connect_only:return
  if state['status']&0xc000!=0xc000:raise RuntimeError('DDR calibration did not pass')
  first_frame=state['frames']
  for frame in range(args.frames):
   suffix='_inverted' if frame%2 else '';reference=ROOT/('build/cyclegan_model/vectors'+suffix)
   raw=(reference/'frame_rgbx.bin').read_bytes();board.command(1);board.wait()
   stream=bytes(((raw[((ty*10+row)*320+tx*10+pixel)*4+channel]-124)>>3)&255
    for ty in range(24) for tx in range(32) for row in range(10) for channel in range(3) for pixel in range(10))
   expected_crc=zlib.crc32(stream)
   for chunk in range(4800):
    board.command(2,payload=int.from_bytes(raw[chunk*64:(chunk+1)*64],'little'));board.wait()
    if chunk%600==599:print(f'STAGE1_LOAD frame={frame} chunks={chunk+1}/4800 seconds={time.monotonic()-begin:.1f}',flush=True)
   ddr_differences=[]
   if args.verify_ddr:
    # Before acquire, slot 0 is selected whenever free; these sequential tests
    # release it after every run. Check every uploaded byte before inference.
    for chunk in range(4800):
     board.command(6,chunk*4);s=board.wait()
     actual_input=s['data'].to_bytes(100,'little')[:64]
     if actual_input!=raw[chunk*64:(chunk+1)*64]:ddr_differences.append(chunk)
     if chunk%1200==1199:print(f'STAGE1_DDR_READ frame={frame} chunks={chunk+1}/4800',flush=True)
    if ddr_differences:raise RuntimeError(f'DDR upload mismatch chunks {ddr_differences}')
   board.command(3)
   # Leave the active DDR/compute interval free of BSCAN transactions.
   # This host guard is excluded from the FPGA cycle counter measurement.
   time.sleep(.05)
   state=board.wait(complete=True)
   stats={k:v for k,v in state.items() if k!='data'}
   if state['frame_id']!=first_frame+frame or state['frames']!=first_frame+frame+1:raise RuntimeError(f'Frame order {stats}')
   # frame_pingpong keeps the final zero-based chunk index, not a chunk total.
   if state['chunks']!=4799:raise RuntimeError(f'Incomplete DDR input {stats}')
   expected=(reference/'encoder3_q44_tiles.bin').read_bytes()
   actual=bytearray()
   for tile in range(384):
    board.command(4,1056+tile);s=board.wait();actual.extend(s['data'].to_bytes(100,'little'))
   (out/f'board_encoder3{suffix}.bin').write_bytes(actual)
   mismatch=sum(a!=b for a,b in zip(actual,expected))
   stats.update(values=len(expected),mismatches=mismatch,input_variant=suffix or 'normal',expected_input_checksum=expected_crc,ddr_verified=args.verify_ddr,compute_ms=state['cycles']/150000,
    expected_sha256=hashlib.sha256(expected).hexdigest(),actual_sha256=hashlib.sha256(actual).hexdigest())
   reports.append(stats);print('STAGE1_FRAME',json.dumps(stats),flush=True)
   if mismatch or state['input_checksum']!=expected_crc or len(actual)!=len(expected) or state['command_wait_cycles']!=0:
    raise RuntimeError('Stage-1 board verification failed')
 finally:
  board.close()
  report=dict(timestamp_utc=datetime.now(timezone.utc).isoformat(),frames=reports,jtag_url=args.url,
   clock_hz=150000000,host_seconds=time.monotonic()-begin,
   bitstream_sha256=hashlib.sha256((project/'outflow/encoder_board.bit').read_bytes()).hexdigest(),
   sources=json.loads((project/'source_manifest.json').read_text()))
  (out/'board_result.json').write_text(json.dumps(report,indent=2)+'\n')
 print('STAGE1_BOARD_PASS',flush=True)
if __name__=='__main__':main()
