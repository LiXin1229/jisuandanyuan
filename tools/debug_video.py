"""Read live SC2210/DDR/current-compute-core/HDMI counters using the camera project's VIO."""
from pathlib import Path
from datetime import datetime, timezone
import argparse, hashlib, json, os, sys, time
ROOT=Path(__file__).resolve().parents[1]
_project_file=ROOT/'build/video_verified/staging_path.txt'
PROJECT=Path(_project_file.read_text().strip()) if _project_file.exists() else ROOT/'build/video_verified'
os.environ.setdefault('EFINITY_USER_DIR',str(PROJECT/'vendor_user'))
sys.path.insert(0,str(Path(os.environ['EFINITY_HOME'])/'debugger/bin'))
from efx_dbg.define import DebugProfileBuilder
from efx_dbg.jtag import JtagManager
from pyftdi.bits import BitSequence

class VideoBoard:
 def __init__(self,url,freq=3e6,profile_path=None):
  self.manager=JtagManager()
  self.jtag=self.manager.config_jtag(url=url,tap='efx_ti',user='USER1',freq=freq)
  p,_=DebugProfileBuilder.from_file(str(profile_path or PROJECT/'debug_profile.json'))
  self.debug=self.manager.config_debug(self.jtag,p);self.manager.validate_debug_cores(self.debug)
  s=self.read();self.signature=s['status']>>16;assert self.signature in (0xe316,),s
  self.toggle=(s['status']>>8)&1
  print('JTAG_CAMERA_CONNECTED '+json.dumps({k:v for k,v in s.items() if k!='data'}),flush=True)
 def read(self):
  v=[int(x) for x in self.manager.read_vio(self.debug,'vio0')]
  if v[0]>>16 not in (0xe316,):
   raise RuntimeError(f'Invalid camera VIO signature 0x{v[0]>>16:04x}; reconnect JTAG and verify the programmed image')
  return dict(status=v[0],cycles=v[1],prefix_mac_cycles=v[2],first_cycle=v[3],processed_frames=v[4]>>16,
   frame_id=v[5],calibration=v[6],encoder_cycles=v[7],residual_cycles=v[8],progress=v[9],
   data=v[10]|v[11]<<256,metric=v[12],completed=(v[9]>>5)&15)
 def command(self,op,arg=0):
  self.toggle^=1
  self.manager.set_vio_probe_out(self.debug,'vio0',[BitSequence((self.toggle<<31)|(op<<28)|arg,length=32)])
  self.manager.write_vio(self.debug,'vio0')
  deadline=time.monotonic()+10
  while True:
   s=self.read()
   if (s['status']>>8)&1==self.toggle:return s
   if time.monotonic()>deadline:raise TimeoutError(s)
 def metric(self,index):return self.command(5,index)['metric']
 def snapshot(self):
  metrics={i:self.metric(i) for i in range(16,32)}
  s=self.read();s.pop('data');s.pop('metric')
  control=metrics[26]
  s.update(displayed_frames=metrics[16],underflows=metrics[17],loaded_lines=metrics[18],hdmi_flags=metrics[19],
   pixel_sum=metrics[20],source_frames=metrics[21],captured_frames=metrics[22],dropped_frames=metrics[23],
   fifo_overflows=metrics[24]>>16,crop_overruns=metrics[24]&65535,
   control_packed=control,input_slots=control&15,configured=bool(control&512),
   key_style=bool(control&256),requested_style=bool(control&128),active_style=bool(metrics[19]&16),
   active_slot=bool(metrics[19]&32),total_sys_cycles=metrics[27],copy_sys_cycles=metrics[28],raw_line_pixels=metrics[29]&2047,
   original_checksum_errors=(metrics[29]>>11)&65535,
   state_word=metrics[30],bus_word=metrics[31])
  state=metrics[30];bus=metrics[31]
  s['states']={name:(state>>shift)&mask for name,shift,mask in [
   ('core',24,7),('scheduler',21,7),('copy',18,7),('writer',16,3),('bridge',14,3),('hdmi',11,7),
   ('write_arb',9,3),('capture_arb',7,3),('core_read_arb',5,3),('display_read_arb',3,3),('native_mux',1,3),('native_type',0,1)]}
  s['bus']={name:bool(bus>>shift&1) for name,shift in [
   ('arvalid',10),('arready',9),('rvalid',8),('rready',7),('rlast',6),('awvalid',5),('awready',4),
   ('wvalid',3),('wready',2),('bvalid',1),('bready',0),('capture_active',11),('video_active',12)]}
  s['compute_ms']=s['cycles']/150000
  s['display_scale']=2 if self.signature==0xe316 else 3
  s['camera_roi']=[640,480] if self.signature==0xe316 else [320,240]
  if self.signature==0xe316:
   gains=self.command(4,0)['metric']
   s['awb_gains_q8']={'r':gains>>20&1023,'g':gains>>10&1023,'b':gains&1023}
   s['expected_original_sum0']=self.command(4,1)['metric']
   s['expected_original_sum1']=self.command(4,2)['metric']
  if self.signature==0xe316:
   diag=[self.command(4,i)['metric'] for i in range(3,7)]
   s['last_original_error']=dict(expected_sum=diag[0],ddr_sum=diag[1],video_sum=diag[2],
    display_frame=diag[3]>>16,slot=diag[3]>>9&1,ddr_lines=diag[3]&511)
  s.update(command_wait_cycles=self.metric(0),data_wait_cycles=self.metric(1),input_checksum=self.metric(2),output_status=self.metric(5),output_cycles=self.metric(14))
  s['copy_ms']=metrics[28]/96000;s['total_ms']=metrics[27]/96000
  return s
 def close(self):self.manager.unconfig_jtag(self.jtag)

def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--url',default='ftdi://0x0403:0x6014/1');p.add_argument('--frequency',type=float,default=3e6)
 p.add_argument('--seconds',type=float,default=3);p.add_argument('--mode',choices=['auto','original','style'],default='auto')
 p.add_argument('--check-switch',action='store_true');p.add_argument('--pause',action='store_true')
 p.add_argument('--profile',type=Path);p.add_argument('--bitstream',type=Path)
 p.add_argument('--output',type=Path,default=ROOT/'build/video_verified/stream_result.json')
 args=p.parse_args();board=VideoBoard(args.url,args.frequency,args.profile)
 control={'auto':0,'original':1,'style':3}[args.mode] | (4 if args.pause else 0)
 try:
  board.command(3,control);initial=board.snapshot();begin=time.monotonic()
  print('CAMERA_INITIAL '+json.dumps(initial),flush=True)
  time.sleep(args.seconds)
  final=board.snapshot();duration=time.monotonic()-begin
  elapsed=lambda key: (final[key]-initial[key])&65535
  rates={key.replace('_frames','_fps'):elapsed(key)/duration for key in ['source_frames','captured_frames','dropped_frames','processed_frames','displayed_frames']}
  switch=[]
  if args.check_switch and final['processed_frames']:
   for name,mode in [('original',1),('style',3),('original',1),('style',3)]:
    board.command(3,mode | (4 if args.pause else 0));time.sleep(.1);s=board.snapshot()
    assert s['active_style']==(name=='style'),s
    switch.append(dict(mode=name,pixel_sum=s['pixel_sum'],underflows=s['underflows']))
   board.command(3,control)
  # Finish the current calculation, sample stable timing, and restore live mode.
  board.command(3,control | 4)
  deadline=time.monotonic()+3
  while board.read()['status']&512:
   if time.monotonic()>deadline:raise TimeoutError('Network did not finish: '+json.dumps(board.snapshot()))
   time.sleep(.01)
  processing_sample=board.snapshot()
  board.command(3,control)
  bit=args.bitstream or PROJECT/'outflow/encoder_board.bit'
  valid=(final['status']&0xc000==0xc000 and not final['status']&0x3c01 and final['configured'] and
   not final['fifo_overflows'] and not final['crop_overruns'] and not final['underflows'] and not final['original_checksum_errors'] and
   final['raw_line_pixels']==1920 and final['processed_frames']>0 and (args.pause or elapsed('processed_frames')>0) and 40<=rates['source_fps']<=80)
  valid=valid and processing_sample['output_status']==7 and processing_sample['command_wait_cycles']==0 and processing_sample['completed']==9 and not processing_sample['status']&0x3e01 and all(x['underflows']==0 for x in switch)
  valid=valid and not processing_sample['fifo_overflows'] and not processing_sample['crop_overruns'] and not processing_sample['underflows']
  report=dict(timestamp_utc=datetime.now(timezone.utc).isoformat(),efinity_version='2026.1.132',
   bitstream_sha256=hashlib.sha256(bit.read_bytes()).hexdigest(),initial=initial,final=final,rates=rates,
   mode_switch=switch,processing_sample=processing_sample,hardware_stream_pass=valid,physical_key_test_performed=False)
  args.output.write_text(json.dumps(report,indent=2)+'\n')
  print(('VIDEO_STREAM_PASS ' if valid else 'VIDEO_STREAM_NOT_VERIFIED ')+json.dumps(report),flush=True)
  if not valid:sys.exit(2)
 finally:board.close()

if __name__=='__main__':main()
