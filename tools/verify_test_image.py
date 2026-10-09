"""Fresh JPEG/checkpoint references and evidence for the deployed generator."""
from pathlib import Path
import argparse,hashlib,json,subprocess,sys,zlib
from datetime import datetime,timezone
import numpy as np
from PIL import Image
from cyclegan_host import ArrayCore,GeneratorScheduler
ROOT=Path(__file__).resolve().parents[1]
REF=Path(r'C:\Users\Administrator\Desktop\jisuan\pe10_10')

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
 ap=argparse.ArgumentParser(description=__doc__)
 ap.add_argument('--prepare',action='store_true');ap.add_argument('--record',action='store_true')
 ap.add_argument('--image',type=Path,default=REF/'test.jpg')
 ap.add_argument('--out',type=Path,default=ROOT/'build/test_jpg_verification')
 ap.add_argument('--project',type=Path)
 args=ap.parse_args();out=args.out.resolve();out.mkdir(parents=True,exist_ok=True)
 project=args.project or Path((ROOT/'build/stage4_verified/staging_path.txt').read_text().strip())
 frozen=json.loads((project/'source_manifest.json').read_text())
 for name,h in frozen['rtl_sha256'].items():assert sha(ROOT/'rtl'/name)==h,(name,'Deployed RTL differs')
 prior=json.loads((ROOT/'docs/analysis/cyclegan_stage4_deployment.json').read_text())
 bit_sha=sha(project/'outflow/encoder_board.bit')
 assert bit_sha==prior['board_boots'][0]['bitstream_sha256']
 model=out/'model';image=args.image.resolve()
 if args.prepare:
  rgb=np.asarray(Image.open(image).convert('RGB'));assert rgb.shape==(240,320,3),'Expected 320x240 RGB; no resize is applied'
  Image.fromarray(rgb).save(out/'input.png')
  subprocess.run([sys.executable,str(REF/'tools/prepare_generator_params.py'),'--checkpoint',str(REF/'netG_B_epoch11.pth'),
   '--image',str(image),'--output',str(model)],check=True)
  manifest=json.loads((model/'params_manifest.json').read_text())
  assert manifest['checkpoint_sha256']==prior['checkpoint_sha256'] and manifest['live_normalization_layers']==0
  assert sha(model/'generator_params_q88.mem')==sha(ROOT/'build/cyclegan_model/generator_params_q88.mem')
  assert sha(model/'tanh_u8.mem')==sha(ROOT/'rtl/mn_tanh_u8.mem')==sha(project/'rtl/mn_tanh_u8.mem')
  raw=np.concatenate([rgb,np.zeros((240,320,1),dtype=np.uint8)],axis=2).tobytes()
  assert (model/'vectors/frame_rgbx.bin').read_bytes()==raw
  weights=[int(v,16) for v in (model/'generator_params_q88.mem').read_text().split()]
  weights=[v-65536 if v>=32768 else v for v in weights]
  lut=[int(v,16) for v in (model/'tanh_u8.mem').read_text().split()]
  core=ArrayCore(weights,lut);scheduler=GeneratorScheduler(core,manifest)
  result=scheduler.run(rgb,verify=model/'vectors')
  Image.fromarray(result.transpose(1,2,0)).save(out/'instruction_reference.png')
  stream=((rgb.astype(np.int64)-124)>>3).astype(np.int8).reshape(24,10,32,10,3).transpose(0,2,1,4,3).tobytes()
  prepared=dict(image=str(image),image_sha256=sha(image),input_rgb_sha256=hashlib.sha256(rgb.tobytes()).hexdigest(),
   input_frame_sha256=hashlib.sha256(raw).hexdigest(),input_checksum=zlib.crc32(stream),shape=[240,320,3],resize=False,
   checkpoint_sha256=manifest['checkpoint_sha256'],parameter_sha256=sha(model/'generator_params_q88.mem'),
   bitstream_sha256=bit_sha,sources=frozen,instruction_layers_checked=len(scheduler.layer_results),instruction_counts=dict(core.counts),
   reference_sha256=sha(model/'vectors/output_u8_tiles.bin'))
  (out/'prepared.json').write_text(json.dumps(prepared,indent=2)+'\n')
  print('TEST_IMAGE_REFERENCE_PASS',prepared['image_sha256'],prepared['reference_sha256'],flush=True)
 if args.record:
  prepared=json.loads((out/'prepared.json').read_text())
  assert prepared['image_sha256']==sha(image) and prepared['bitstream_sha256']==bit_sha and prepared['sources']==frozen
  assert prepared['instruction_layers_checked']==16
  boots=[];expected=(model/'vectors/output_u8_tiles.bin').read_bytes()
  expected_rgb=np.load(model/'vectors/output_u8.npy').transpose(1,2,0)
  for index,mode in enumerate(('paused','continuous')):
   report=json.loads((out/mode/'board_result.json').read_text())
   assert report['failure'] is None and report['bitstream_sha256']==bit_sha and report['sources']==frozen and len(report['frames'])==1
   f=report['frames'][0]
   assert f['input_checksum']==f['expected_input_checksum']==prepared['input_checksum']
   assert f['frame_id']==index and f['frames']==index+1 and f['chunks']==4799 and f['phy_phase']==6
   assert f['blocks_completed']==9 and f['layers_completed']==3 and f['output_completed'] and f['command_wait_cycles']==0
   assert [v['block'] for v in f['blocks']]==(list(range(1,10)) if mode=='paused' else [])
   assert [v['layer'] for v in f['layers']]==([1,2,3,4] if mode=='paused' else [4])
   assert f['ddr_verified']==(mode=='paused') and f['mismatches']==0
   for v in f['blocks']+f['layers']:assert v['mismatches']==0 and v['actual_sha256']==v['expected_sha256']
   actual=(out/mode/'board_layer4.bin').read_bytes();assert actual==expected and len(actual)==230400
   actual_rgb=np.asarray(Image.open(out/mode/'board_output.png'));assert np.array_equal(actual_rgb,expected_rgb)
   boots.append(report)
  program=(out/'program.log').read_text();assert '0x10660A79' in program and 'finished with JTAG programming' in program
  record=dict(recorded_utc=datetime.now(timezone.utc).isoformat(),network_commit='ac1fbbc',
   contract='FPGA equals the current Q4.4/Q8.8 fixed-normalization integer generator; independent scatter and encoded-instruction references',
   input=prepared,board_runs=boots,verified_values=sum(r['frames'][0]['values'] for r in boots),
   final_rgb_values=460800,final_rgb_mismatches=0,final_rgb_max_absolute_error=0,final_rgb_mean_absolute_error=0,
   artifacts={name:str((out/name).relative_to(ROOT)) for name in ('input.png','instruction_reference.png','paused/board_output.png','continuous/board_output.png')},
   tool_sha256={name:sha(ROOT/name) for name in ('tools/verify_test_image.py','tools/debug_output_deployment.py','scripts/run_test_image_board.ps1')})
  (out/'verification.json').write_text(json.dumps(record,indent=2)+'\n')
  (ROOT/'docs/analysis/cyclegan_test_jpg_verification.json').write_text(json.dumps(record,indent=2)+'\n')
  print('TEST_IMAGE_BOARD_PASS',record['verified_values'],'activation values, 460800 RGB bytes, zero mismatches',flush=True)

if __name__=='__main__':main()
