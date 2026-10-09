"""Stage-4 board gate: entire generator through 7x7/Tanh and RGB DDR output."""
from pathlib import Path
import argparse,hashlib,json,os,time,zlib
from datetime import datetime,timezone
from debug_encoder_deployment import Board as BaseBoard,ROOT

class Board(BaseBoard):
 def __init__(self,project,url,freq):
  self.statistics_cache={}
  super().__init__(project,url,freq,signature=0xe315)
 def read(self):
  v=[int(x) for x in self.manager.read_vio(self.debug,'vio0')]
  return dict(self.statistics_cache,status=v[0],paused=bool(v[0]&4),data=sum(x<<(200*i) for i,x in enumerate(v[1:5])))
 def snapshot(self):
  v=[]
  for index in range(18):
   self.command(4,(1<<27)|index);s=self.wait();v.append(s['data']&0xffffffff)
  self.statistics_cache=dict(cycles=v[0],busy_cycles=v[1],first_output=v[2],frames=v[3]>>16,chunks=v[3]&65535,
   frame_id=v[4],calibration=v[5],command_wait_cycles=v[6],data_wait_cycles=v[7],input_checksum=v[8],
   blocks_completed=(v[9]>>1)&15,output_base=(v[9]>>5)&2047,encoder_cycles=v[10],residual_cycles=v[11],block_cycles=v[12],
   layers_completed=v[13]&3,decoder_cycles=v[14],layer_cycles=v[15],output_cycles=v[16],output_completed=bool(v[17]&1),phy_phase=(v[5]>>10)&7)
  return dict(s,**self.statistics_cache)
 def wait_pause(self,block=None,layer=None,output=False):
  deadline=time.monotonic()+30
  while True:
   s=self.wait()
   if s['paused']:
    s=self.snapshot()
    if (block is None or s['blocks_completed']==block) and (layer is None or s['layers_completed']==layer) and (not output or s['output_completed']):return s
   if time.monotonic()>deadline:raise TimeoutError(f'Pause timeout block={block} layer={layer} state={s}')

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--project',type=Path);ap.add_argument('--url',required=True)
 ap.add_argument('--out',type=Path,default=ROOT/'build/stage4_verified');ap.add_argument('--frames',type=int,default=2)
 ap.add_argument('--frequency',type=float,default=3e6);ap.add_argument('--continuous',action='store_true');ap.add_argument('--verify-ddr',action='store_true')
 args=ap.parse_args();project=args.project or Path((args.out/'staging_path.txt').read_text().strip())
 os.environ.setdefault('EFINITY_USER_DIR',str(project/'vendor_user'));args.out.mkdir(parents=True,exist_ok=True)
 board=Board(project,args.url,args.frequency);reports=[];begin=time.monotonic();failure=None;state={}
 try:
  board.command(5,8|6);board.wait();state=board.snapshot();first_frame=state['frames']
  if state['status']&0xc000!=0xc000:raise RuntimeError('DDR calibration did not pass')
  for frame in range(args.frames):
   suffix='_inverted' if frame%2 else '';reference=ROOT/('build/cyclegan_model/vectors'+suffix)
   raw=(reference/'frame_rgbx.bin').read_bytes();board.command(1);board.wait()
   stream=bytes(((raw[((ty*10+row)*320+tx*10+pixel)*4+channel]-124)>>3)&255
    for ty in range(24) for tx in range(32) for row in range(10) for channel in range(3) for pixel in range(10))
   expected_crc=zlib.crc32(stream)
   for chunk in range(4800):
    board.command(2,payload=int.from_bytes(raw[chunk*64:(chunk+1)*64],'little'));board.wait()
    if chunk%1200==1199:print(f'STAGE4_LOAD frame={frame} chunks={chunk+1}/4800 seconds={time.monotonic()-begin:.1f}',flush=True)
   if args.verify_ddr:
    for chunk in range(4800):
     board.command(6,chunk*4);s=board.wait()
     if s['data'].to_bytes(100,'little')[:64]!=raw[chunk*64:(chunk+1)*64]:raise RuntimeError(f'RGB DDR mismatch chunk={chunk}')
     if chunk%1200==1199:print(f'STAGE4_RGB_DDR_PASS chunks={chunk+1}/4800',flush=True)
   board.command(3,int(not args.continuous));time.sleep(.15)
   blocks=[];layers=[]
   if not args.continuous:
    for block in range(1,10):
     state=board.wait_pause(block=block,layer=0)
     if state['input_checksum']!=expected_crc:raise RuntimeError(f'Actual input CRC mismatch {state}')
     actual=bytearray();expected=(reference/f'block{block}_q44_tiles.bin').read_bytes()
     for tile in range(384):
      board.command(4,state['output_base']+tile);s=board.wait();actual.extend(s['data'].to_bytes(100,'little'))
     check=compare(expected,actual,block=block,cycles=state['block_cycles']);blocks.append(check)
     print('STAGE4_RESIDUAL',json.dumps(check),flush=True)
     board.command(7);board.wait();time.sleep(.03)
   for layer in (range(1,5) if not args.continuous else [4]):
    if args.continuous:board.wait(complete=True);state=board.snapshot()
    else:state=board.wait_pause(block=9,layer=min(layer,3),output=layer==4)
    if state['input_checksum']!=expected_crc:raise RuntimeError(f'Actual input CRC mismatch {state}')
    expected=(reference/('output_u8_tiles.bin' if layer==4 else f'stage{layer}_q44_tiles.bin')).read_bytes();actual=bytearray();base=(layer+2)<<20
    for tile in range(len(expected)//100):
     for half in range(2):
      board.command(6,(base+tile*128+half*64)>>4);s=board.wait();reply=s['data'].to_bytes(100,'little')[:64]
      if reply[50:]!=bytes(14):raise RuntimeError(f'DDR padding layer={layer} tile={tile} half={half}')
      actual.extend(reply[:50])
     if tile%1536==1535:print(f'STAGE4_READ frame={frame} layer={layer} tiles={tile+1}/{len(expected)//100}',flush=True)
    (args.out/f'board_layer{layer}{suffix}.bin').write_bytes(actual)
    if layer==4:save_rgb(actual,args.out/f'board_output{suffix}.png')
    check=compare(expected,actual,layer=layer,cycles=state['layer_cycles'] if layer!=4 else state['output_cycles'],decoder_cycles=state['decoder_cycles']);layers.append(check)
    print('STAGE4_LAYER',json.dumps(check),flush=True)
    if not args.continuous:board.command(7);board.wait();time.sleep(.1)
   board.wait(complete=True);state=board.snapshot()
   if state['frame_id']!=first_frame+frame or state['frames']!=first_frame+frame+1:raise RuntimeError('Frame ordering')
   if not state['output_completed'] or state['layers_completed']!=3 or state['blocks_completed']!=9 or state['chunks']!=4799 or state['phy_phase']!=6 or state['command_wait_cycles']!=0:raise RuntimeError('Prefix counters/instruction starvation')
   stats={k:v for k,v in state.items() if k!='data'}
   stats.update(blocks=blocks,layers=layers,mode='continuous' if args.continuous else 'layer_readback',
    input_variant=suffix or 'normal',expected_input_checksum=expected_crc,ddr_verified=args.verify_ddr,
    values=sum(x['values'] for x in blocks+layers),mismatches=0,compute_ms=state['cycles']/150000,decoder_ms=state['decoder_cycles']/150000,output_ms=state['output_cycles']/150000)
   reports.append(stats);print('STAGE4_FRAME',json.dumps(stats),flush=True)
 except Exception as exc:
  failure=dict(error=str(exc),state={k:v for k,v in state.items() if k!='data'});raise
 finally:
  board.close()
  report=dict(timestamp_utc=datetime.now(timezone.utc).isoformat(),frames=reports,failure=failure,jtag_url=args.url,
   host_seconds=time.monotonic()-begin,clock_hz=150000000,
   bitstream_sha256=hashlib.sha256((project/'outflow/encoder_board.bit').read_bytes()).hexdigest(),
   sources=json.loads((project/'source_manifest.json').read_text()))
  (args.out/'board_result.json').write_text(json.dumps(report,indent=2)+'\n')
 print('STAGE4_BOARD_PASS',flush=True)

def save_rgb(tiles,path):
 # Reassemble the four 5x5 quadrants per tile into interleaved RGB PNG.
 import struct
 image=bytearray(240*320*3)
 for channel in range(3):
  for ty in range(24):
   for tx in range(32):
    tile=tiles[(channel*768+ty*32+tx)*100:][:100]
    for y in range(10):
     for x in range(10):
      image[((ty*10+y)*320+tx*10+x)*3+channel]=tile[((y//5)*2+x//5)*25+(y%5)*5+x%5]
 def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data))
 scan=b''.join(b'\0'+image[y*960:(y+1)*960] for y in range(240))
 path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',320,240,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(scan))+chunk(b'IEND',b''))

def compare(expected,actual,**metadata):
 mismatch=sum(a!=b for a,b in zip(actual,expected))
 check=dict(metadata,values=len(expected),mismatches=mismatch,expected_sha256=hashlib.sha256(expected).hexdigest(),actual_sha256=hashlib.sha256(actual).hexdigest())
 if len(actual)!=len(expected) or mismatch:raise RuntimeError(f'Value comparison failed: {check}')
 return check

if __name__=='__main__':main()
