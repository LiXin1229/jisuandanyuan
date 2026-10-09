"""Compare a captured live frame against fresh integer references, then record gates."""
from pathlib import Path
import argparse,hashlib,json,re,subprocess,sys,zlib
from datetime import datetime,timezone
import numpy as np
from PIL import Image
from cyclegan_host import ArrayCore,GeneratorScheduler
ROOT=Path(__file__).resolve().parents[1]
REF=Path(r'C:/Users/Administrator/Desktop/jisuan/pe10_10')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def pair_check(pair):
 report=json.loads((pair/'capture_report.json').read_text());assert report['pass_matched_capture']
 raw=(pair/'camera_original.rgbx').read_bytes();rgbx=np.frombuffer(raw,dtype=np.uint8).reshape(240,320,4)
 assert not np.any(rgbx[:,:,3]);rgb=rgbx[:,:,:3];Image.fromarray(rgb).save(pair/'camera_original.png')
 stream=((rgb.astype(np.int64)-124)>>3).astype(np.int8).reshape(24,10,32,10,3).transpose(0,2,1,4,3).tobytes()
 assert zlib.crc32(stream)==report['frozen']['input_checksum'],'Captured original differs from actual network input CRC'
 model=pair/'reference'
 with (pair/'reference.log').open('w') as log:
  subprocess.run([sys.executable,str(REF/'tools/prepare_generator_params.py'),'--checkpoint',str(REF/'netG_B_epoch11.pth'),
   '--image',str(pair/'camera_original.png'),'--output',str(model)],stdout=log,stderr=subprocess.STDOUT,check=True)
 manifest=json.loads((model/'params_manifest.json').read_text());assert manifest['live_normalization_layers']==0
 assert sha(model/'generator_params_q88.mem')==sha(ROOT/'build/cyclegan_model/generator_params_q88.mem')
 weights=[int(x,16) for x in (model/'generator_params_q88.mem').read_text().split()]
 weights=[x-65536 if x>=32768 else x for x in weights]
 lut=[int(x,16) for x in (model/'tanh_u8.mem').read_text().split()]
 scheduler=GeneratorScheduler(ArrayCore(weights,lut),manifest);result=scheduler.run(rgb,verify=model/'vectors')
 assert len(scheduler.layer_results)==16
 padded=np.frombuffer((pair/'fpga_styled.tiles').read_bytes(),dtype=np.uint8).reshape(2304,128)
 assert not np.any(padded[:,50:64]) and not np.any(padded[:,114:128])
 packed=np.concatenate((padded[:,:50],padded[:,64:114]),axis=1).tobytes()
 expected=(model/'vectors/output_u8_tiles.bin').read_bytes();assert len(packed)==len(expected)==230400
 mismatch=sum(a!=b for a,b in zip(packed,expected));assert mismatch==0,('Live frame differs from integer reference',mismatch)
 actual=np.frombuffer(packed,dtype=np.uint8).reshape(3,24,32,2,2,5,5).transpose(0,1,3,5,2,4,6).reshape(3,240,320)
 assert np.array_equal(actual,result)
 Image.fromarray(actual.transpose(1,2,0)).save(pair/'fpga_styled.png')
 Image.fromarray(result.transpose(1,2,0)).save(pair/'instruction_reference.png')
 comparison=dict(timestamp_utc=datetime.now(timezone.utc).isoformat(),input_rgbx_sha256=sha(pair/'camera_original.rgbx'),
  checkpoint_sha256=manifest['checkpoint_sha256'],parameter_sha256=sha(model/'generator_params_q88.mem'),
  fpga_padded_sha256=sha(pair/'fpga_styled.tiles'),output_rgb_sha256=hashlib.sha256(actual.tobytes()).hexdigest(),
  values=230400,mismatches=mismatch,instruction_layers_checked=16,input_checksum=zlib.crc32(stream),max_absolute_error=0,mean_absolute_error=0,
  original_hdmi_sum=report['original_measured_hdmi_sum'],styled_hdmi_sum=report['styled_measured_hdmi_sum'])
 (pair/'comparison.json').write_text(json.dumps(comparison,indent=2)+'\n')
 print('VIDEO_PAIR_NUMERICAL_PASS 230400 RGB bytes; independent scatter and 16 instruction-model tensors',flush=True)

def record(out,pair,confirmation):
 project=Path((out/'staging_path.txt').read_text().strip());manifest=json.loads((project/'source_manifest.json').read_text())
 assert all(sha(ROOT/'rtl'/name)==value for name,value in manifest['rtl_sha256'].items())
 assert all(sha(ROOT/'board/video'/name)==value for name,value in manifest['board_sha256'].items())
 prior=json.loads((ROOT/'docs/analysis/cyclegan_stage4_deployment.json').read_text())
 base_sources=prior['board_boots'][0]['sources']['rtl_sha256']
 assert all(manifest['rtl_sha256'][name]==value for name,value in base_sources.items()),'The verified compute RTL changed'
 assert 'video_core_protocol_model' not in (project/'encoder_board.xml').read_text()
 for flow in ('map','pnr','pgm'):assert re.search(flow+r'\s*:\s*PASS',(project/(flow+'.console.log')).read_text())
 units={}
 for name in ('frontend','isp640','pool','key','stream','hdmi','board'):
  p=out/(name+'_sim.log');log=p.read_text();assert 'PASS camera' in log and '** Fatal' not in log
  units[name]={'sha256':sha(p),'pass_line':next(x.strip() for x in log.splitlines() if 'PASS camera' in x)}
 resources=json.loads((out/'resources.json').read_text());assert resources['EFX_DSP48']==103 and resources['EFX_RAM10']+resources['EFX_DPRAM10']<=256
 timing=(project/'outflow/encoder_board.timing.rpt').read_text();rows=re.findall(r'^\s*(\w+)\s+(\w+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+\(',timing,re.M)
 assert rows and all(float(row[3])>=0 for row in rows)
 streams=[json.loads((out/name).read_text()) for name in ('stream_style.json','stream_original.json')]
 restored=json.loads((out/'stream_restore.json').read_text())
 assert restored['hardware_stream_pass'] and (restored['final']['control_packed']>>10)&7==0
 bit_sha=sha(project/'outflow/encoder_board.bit')
 for stream in streams:assert stream['hardware_stream_pass'] and stream['bitstream_sha256']==bit_sha
 capture=json.loads((pair/'capture_report.json').read_text());comparison=json.loads((pair/'comparison.json').read_text())
 assert capture['pass_matched_capture'] and capture['bitstream_sha256']==bit_sha and comparison['mismatches']==0 and comparison['values']==230400
 assert comparison['input_rgbx_sha256']==sha(pair/'camera_original.rgbx') and comparison['fpga_padded_sha256']==sha(pair/'fpga_styled.tiles')
 log=(out/'program.log').read_text();assert '0x10660A79' in log and 'finished with JTAG programming' in log
 result=dict(timestamp_utc=datetime.now(timezone.utc).isoformat(),base_network_commit='ac1fbbc',
  bitstream_sha256=bit_sha,sources=manifest,resources=resources,timing_rows=rows,simulations=units,
  live_streams=streams,restored_auto_control=restored,matched_capture=capture,numerical_comparison=comparison,
  tool_sha256={name:sha(ROOT/name) for name in ('tools/prepare_video_deployment.py','tools/debug_video.py','tools/capture_video_pair.py','tools/verify_video_deployment.py','scripts/run_video_board.ps1','scripts/run_video_modelsim.ps1','scripts/verify_video_board.ps1')},
  simulation_source_sha256={p.name:sha(p) for p in (ROOT/'sim/video').iterdir() if p.is_file()},
  report_sha256={name:sha(project/'outflow'/name) for name in ('encoder_board.map.rpt','encoder_board.timing.rpt')},
  physical_monitor_visual_confirmation=bool(confirmation),physical_key_press_test_performed=bool(confirmation),
  physical_user_confirmation=confirmation or None,
  measurement='Reference compute RTL unchanged; real video-interface RTL simulations and live same-frame numerical comparison',
  artifacts={'input':str((pair/'camera_original.png').relative_to(ROOT)),'fpga_output':str((pair/'fpga_styled.png').relative_to(ROOT))})
 (out/'verification.json').write_text(json.dumps(result,indent=2)+'\n')
 (ROOT/'docs/analysis/cyclegan_video_deployment.json').write_text(json.dumps(result,indent=2)+'\n')
 print('VIDEO_DEPLOYMENT_PASS',flush=True)

if __name__=='__main__':
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--pair',type=Path,required=True);ap.add_argument('--record',action='store_true')
 ap.add_argument('--out',type=Path,default=ROOT/'build/video_verified');ap.add_argument('--physical-confirmation');args=ap.parse_args()
 if args.record:record(args.out.resolve(),args.pair.resolve(),args.physical_confirmation)
 else:pair_check(args.pair.resolve())
