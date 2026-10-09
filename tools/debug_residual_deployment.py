"""Board gate: actual input CRC, nine full block readbacks, autonomous run."""
from pathlib import Path
import argparse,hashlib,json,os,time,zlib
from datetime import datetime,timezone
from debug_encoder_deployment import Board as EncoderBoard,ROOT

class Board(EncoderBoard):
 def __init__(self,project,url,freq):
  profile=json.loads((project/'debug_profile.json').read_text())
  self.compact=profile['debug_cores'][0]['uuid'].startswith('e313')
  self.statistics_cache=dict.fromkeys(('cycles','busy_cycles','first_output','frames','chunks','frame_id','calibration',
   'command_wait_cycles','data_wait_cycles','input_checksum','blocks_completed','output_base','encoder_cycles',
   'residual_cycles','block_cycles','calibration_phase','phy_phase'),0)
  super().__init__(project,url,freq,signature=0xe313 if self.compact else 0xe312)
 def read(self):
  v=[int(x) for x in self.manager.read_vio(self.debug,'vio0')]
  if self.compact:
   return dict(self.statistics_cache,status=v[0],paused=bool(v[0]&4),data=sum(x<<(200*i) for i,x in enumerate(v[1:5])))
  return dict(status=v[0],cycles=v[1],busy_cycles=v[2],first_output=v[3],frames=v[4]>>16,
   chunks=v[4]&65535,frame_id=v[5],calibration=v[6],data=sum(x<<(200*i) for i,x in enumerate(v[7:11])),
   command_wait_cycles=v[11],data_wait_cycles=v[12],input_checksum=v[13],paused=bool(v[14]&1),
   blocks_completed=(v[14]>>1)&15,output_base=(v[14]>>5)&2047,
   encoder_cycles=v[15],residual_cycles=v[16],block_cycles=v[17],calibration_phase=(v[6]>>7)&7,phy_phase=(v[6]>>10)&7)
 def snapshot(self):
  if not self.compact:return self.wait()
  v=[]
  # Counters are stable while idle/paused, so all words belong to one
  # quiescent point without adding a wide snapshot register in the FPGA.
  for index in range(13):
   self.command(4,(1<<27)|index);s=self.wait();v.append(s['data']&0xffffffff)
  self.statistics_cache=dict(cycles=v[0],busy_cycles=v[1],first_output=v[2],frames=v[3]>>16,chunks=v[3]&65535,
   frame_id=v[4],calibration=v[5],command_wait_cycles=v[6],data_wait_cycles=v[7],input_checksum=v[8],
   blocks_completed=(v[9]>>1)&15,output_base=(v[9]>>5)&2047,encoder_cycles=v[10],residual_cycles=v[11],block_cycles=v[12],
   calibration_phase=(v[5]>>7)&7,phy_phase=(v[5]>>10)&7)
  return dict(s,**self.statistics_cache)
 def wait_block(self,block,timeout=30):
  deadline=time.monotonic()+timeout
  while True:
   s=self.wait()
   if s['paused']:
    s=self.snapshot()
    if s['blocks_completed']==block:return s
   if time.monotonic()>deadline:raise TimeoutError(f'Block {block} timeout {s}')

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--project',type=Path);ap.add_argument('--url',required=True)
 ap.add_argument('--out',type=Path,default=ROOT/'build/stage2')
 ap.add_argument('--frames',type=int,default=2,choices=[1,2,4]);ap.add_argument('--frequency',type=float,default=3e6)
 ap.add_argument('--verify-ddr',action='store_true');ap.add_argument('--mixed',action='store_true')
 ap.add_argument('--continuous',action='store_true');ap.add_argument('--phy-phase',type=int,choices=range(8));args=ap.parse_args()
 project=args.project or Path((ROOT/'build/stage2/staging_path.txt').read_text().strip())
 os.environ.setdefault('EFINITY_USER_DIR',str(project/'vendor_user'))
 out=args.out;out.mkdir(parents=True,exist_ok=True)
 board=Board(project,args.url,args.frequency);reports=[];begin=time.monotonic();failure=None
 try:
  board.command(5,0 if args.phy_phase is None else 8|args.phy_phase);board.wait();state=board.snapshot()
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
    if chunk%1200==1199:print(f'STAGE2_LOAD frame={frame} chunks={chunk+1}/4800 seconds={time.monotonic()-begin:.1f}',flush=True)
   if args.verify_ddr:
    for chunk in range(4800):
     board.command(6,chunk*4);s=board.wait()
     if s['data'].to_bytes(100,'little')[:64]!=raw[chunk*64:(chunk+1)*64]:raise RuntimeError(f'DDR mismatch {chunk}')
     if chunk%1200==1199:print(f'STAGE2_DDR_READ frame={frame} chunks={chunk+1}/4800',flush=True)
   pausing=not args.continuous and not (args.mixed and frame>=2)
   board.command(3,int(pausing));time.sleep(.05)
   blocks=[]
   for block in (range(1,10) if pausing else [9]):
    if pausing:state=board.wait_block(block)
    else:board.wait(complete=True);state=board.snapshot()
    if state['input_checksum']!=expected_crc:raise RuntimeError(f'Actual input CRC mismatch {state}')
    expected=(reference/f'block{block}_q44_tiles.bin').read_bytes();actual=bytearray()
    for tile in range(384):
     board.command(4,state['output_base']+tile);s=board.wait();actual.extend(s['data'].to_bytes(100,'little'))
    (out/f'board_block{block}{suffix}.bin').write_bytes(actual)
    mismatch=sum(a!=b for a,b in zip(actual,expected))
    check=dict(block=block,values=len(expected),mismatches=mismatch,cycles=state['block_cycles'],
     cumulative_cycles=state['residual_cycles'],output_base=state['output_base'],
     expected_sha256=hashlib.sha256(expected).hexdigest(),actual_sha256=hashlib.sha256(actual).hexdigest())
    blocks.append(check);print('STAGE2_BLOCK',json.dumps(check),flush=True)
    if len(actual)!=len(expected) or mismatch:raise RuntimeError(f'Block {block} board mismatch {mismatch}')
    if pausing:board.command(7);board.wait()
   board.wait(complete=True);state=board.snapshot()
   stats={k:v for k,v in state.items() if k!='data'}
   stats.update(blocks=blocks,values=sum(b['values'] for b in blocks),mismatches=sum(b['mismatches'] for b in blocks),
    mode='block_readback' if pausing else 'continuous',input_variant=suffix or 'normal',expected_input_checksum=expected_crc,
    ddr_verified=args.verify_ddr,compute_ms=state['cycles']/150000,residual_ms=state['residual_cycles']/150000)
   reports.append(stats);print('STAGE2_FRAME',json.dumps(stats),flush=True)
   if state['frame_id']!=first_frame+frame or state['frames']!=first_frame+frame+1:raise RuntimeError('Frame ordering')
   if state['chunks']!=4799 or state['blocks_completed']!=9 or state['command_wait_cycles']!=0:raise RuntimeError('Stage-2 counter verification')
 except Exception as exc:
  failure=dict(error=str(exc),state={k:v for k,v in state.items() if k!='data'})
  raise
 finally:
  board.close()
  report=dict(timestamp_utc=datetime.now(timezone.utc).isoformat(),frames=reports,jtag_url=args.url,
   clock_hz=150000000,host_seconds=time.monotonic()-begin,
   bitstream_sha256=hashlib.sha256((project/'outflow/encoder_board.bit').read_bytes()).hexdigest(),
   sources=json.loads((project/'source_manifest.json').read_text()),failure=failure)
  (out/'board_result.json').write_text(json.dumps(report,indent=2)+'\n')
 print('STAGE2_BOARD_PASS',flush=True)
if __name__=='__main__':main()
