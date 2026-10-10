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

def compute_schedule_check(out,manifest,base_sources):
 changed=[name for name,value in base_sources.items() if manifest['rtl_sha256'][name]!=value]
 if not changed:return None
 assert changed==['mobilenet_unit.sv'],('Unvalidated compute changes',changed)
 def tested_sources(stage,min_sources=18):
  hashes={name:sha(stage/name) for name in base_sources if (stage/name).exists()}
  assert len(hashes)>=min_sources and 'mobilenet_unit.sv' in hashes
  assert all(value==manifest['rtl_sha256'][name] for name,value in hashes.items()),'Simulation used stale compute RTL'
  return hashes
 unit_stage=Path((out/'unit_staging_path.txt').read_text(encoding='utf-8-sig').strip())
 unit_sources=tested_sources(unit_stage,min_sources=10)
 assert sha(unit_stage/'sim/vectors.txt')==sha(ROOT/'sim/vectors.txt'),'Stale unit vectors'
 assert sha(unit_stage/'tb_mobilenet_unit.sv')==sha(ROOT/'sim/tb_mobilenet_unit.sv')
 unit_logs={}
 for name,marker in [('unit.log','PASS:'),('bus.log','PASS bus:'),('executor_cycles.log','PASS cycle model:')]:
  p=out/name;log=p.read_text();assert marker in log and '** Fatal' not in log
  unit_logs[name]=dict(sha256=sha(p),pass_line=next(x.strip() for x in log.splitlines() if marker in x))
 cycle_check=subprocess.run([sys.executable,str(ROOT/'sim/check_executor_cycles.py'),
  '--vectors',str(unit_stage/'sim/vectors.txt'),'--metrics',str(out/'commands.csv')],capture_output=True,text=True,check=True)
 native={}
 for folder,stem in [('full_native','native'),('full_native_inverted','native_inverted_delay45')]:
  p=out/folder/(stem+'.log');log=p.read_text()
  assert 'PASS stage4: full_prefix=1 output_only=0 values=1075200 residual_values=345600 commands=170880' in log and '** Fatal' not in log
  assert re.search(r'PASS stage4:.* command_wait=0 ',log)
  stage=Path((out/folder/(stem+'_path.txt')).read_text(encoding='utf-8-sig').strip())
  assert sha(stage/'tb_cyclegan_output.sv')==sha(ROOT/'sim/tb_cyclegan_output.sv')
  inverted=folder=='full_native_inverted';suffix='_inverted' if inverted else ''
  assert ('DDR delay=45' if inverted else 'DDR delay=2') in log
  assert ('+continuous' if inverted else '+paused') in log
  vector_source=ROOT/'build/stage4'/('vectors'+suffix)
  vector_copy=stage/'build/stage4'/('vectors'+suffix)
  vector_hashes={v.name:sha(vector_copy/v.name) for v in vector_source.glob('*.mem')}
  assert len(vector_hashes)>=15 and all(value==sha(vector_source/name) for name,value in vector_hashes.items()),'Stale native references'
  native[folder]=dict(sha256=sha(p),pass_line=next(x.strip() for x in log.splitlines() if 'PASS stage4:' in x),
   rtl_sha256=tested_sources(stage),vectors_sha256=vector_hashes)
 return dict(changed_compute_rtl=changed,unit_sources=unit_sources,unit_logs=unit_logs,
  vectors_sha256=sha(ROOT/'sim/vectors.txt'),metrics_sha256=sha(out/'commands.csv'),
  cycle_check=cycle_check.stdout.strip(),full_network_simulations=native)

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

def record(out,pair,confirmation,record_path=None,baseline_path=None):
 project=Path((out/'staging_path.txt').read_text(encoding='utf-8-sig').strip());manifest=json.loads((project/'source_manifest.json').read_text())
 assert all(sha(ROOT/'rtl'/name)==value for name,value in manifest['rtl_sha256'].items())
 assert all(sha(ROOT/'board/video'/name)==value for name,value in manifest['board_sha256'].items())
 prior=json.loads((ROOT/'docs/analysis/cyclegan_stage4_deployment.json').read_text())
 base_sources=prior['board_boots'][0]['sources']['rtl_sha256']
 compute_evidence=compute_schedule_check(out,manifest,base_sources)
 assert 'video_core_protocol_model' not in (project/'encoder_board.xml').read_text()
 for flow in ('map','pnr','pgm'):assert re.search(flow+r'\s*:\s*PASS',(project/(flow+'.console.log')).read_text())
 units={}
 for name in ('frontend','isp640','pool','key','stream','hdmi','board'):
  p=out/(name+'_sim.log');log=p.read_text();assert 'PASS camera' in log and '** Fatal' not in log
  units[name]={'sha256':sha(p),'pass_line':next(x.strip() for x in log.splitlines() if 'PASS camera' in x)}
 resources=json.loads((out/'resources.json').read_text());assert resources['EFX_DSP48']==103 and resources['EFX_RAM10']+resources['EFX_DPRAM10']<=256
 timing=(project/'outflow/encoder_board.timing.rpt').read_text();rows=re.findall(r'^\s*(\w+)\s+(\w+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+\(',timing,re.M)
 assert rows and all(float(row[3])>=0 for row in rows)
 compute_mhz=manifest['video_contract'].get('compute_mhz',150)
 clock=re.search(r'^clk_compute\s+([\d.]+)\s+([\d.]+)\s+\{',timing,re.M)
 # The report rounds periods to 0.001 ns and derives displayed MHz from them.
 assert clock and abs(float(clock[1])-1000/compute_mhz)<=.0005,'Clock contract differs from routed clock'
 streams=[json.loads((out/name).read_text()) for name in ('stream_style.json','stream_original.json')]
 restored=json.loads((out/'stream_restore.json').read_text())
 assert restored['hardware_stream_pass'] and (restored['final']['control_packed']>>10)&7==0
 bit_sha=sha(project/'outflow/encoder_board.bit')
 for stream in streams:
  assert stream['hardware_stream_pass'] and stream['bitstream_sha256']==bit_sha
  assert stream['processing_sample']['compute_mhz']==compute_mhz,'Incorrect frequency in timing measurement'
 capture=json.loads((pair/'capture_report.json').read_text());comparison=json.loads((pair/'comparison.json').read_text())
 assert capture['pass_matched_capture'] and capture['bitstream_sha256']==bit_sha and comparison['mismatches']==0 and comparison['values']==230400
 assert comparison['input_rgbx_sha256']==sha(pair/'camera_original.rgbx') and comparison['fpga_padded_sha256']==sha(pair/'fpga_styled.tiles')
 log=(out/'program.log').read_text();assert '0x10660A79' in log and 'finished with JTAG programming' in log
 result=dict(timestamp_utc=datetime.now(timezone.utc).isoformat(),base_network_commit='ac1fbbc',
  bitstream_sha256=bit_sha,sources=manifest,resources=resources,timing_rows=rows,simulations=units,
  live_streams=streams,restored_auto_control=restored,matched_capture=capture,numerical_comparison=comparison,
  tool_sha256={name:sha(ROOT/name) for name in ('tools/prepare_video_deployment.py','tools/debug_video.py','tools/capture_video_pair.py','tools/verify_video_deployment.py','scripts/run_video_board.ps1','scripts/run_video_modelsim.ps1','scripts/verify_video_board.ps1',
   'scripts/run_unit_modelsim.ps1','scripts/run_output_modelsim.ps1','sim/generate_vectors.py','sim/check_executor_cycles.py','sim/tb_mobilenet_unit.sv','sim/tb_cyclegan_output.sv')},
  simulation_source_sha256={p.name:sha(p) for p in (ROOT/'sim/video').iterdir() if p.is_file()},
  report_sha256={name:sha(project/'outflow'/name) for name in ('encoder_board.map.rpt','encoder_board.timing.rpt')},
  physical_monitor_visual_confirmation=bool(confirmation),physical_key_press_test_performed=bool(confirmation),
  physical_user_confirmation=confirmation or None,
  compute_schedule_verification=compute_evidence,
  measurement=('Native full-network and unit regressions for changed load scheduling; real video-interface RTL simulations and live same-frame numerical comparison' if compute_evidence else
   'Reference compute RTL unchanged; real video-interface RTL simulations and live same-frame numerical comparison'),
  artifacts={'input':str((pair/'camera_original.png').relative_to(ROOT)),'fpga_output':str((pair/'fpga_styled.png').relative_to(ROOT))})
 if baseline_path:
  baseline_path=baseline_path.resolve()
  baseline=json.loads(baseline_path.read_text());previous=baseline['resources']
  deltas={name:resources[name]-previous[name] for name in resources}
  assert deltas['EFX_DSP48']==0 and deltas['EFX_RAM10']+deltas['EFX_DPRAM10']==0,'Storage/DSP budget increased'
  assert deltas['EFX_LUT4']<=64 and deltas['EFX_FF']<=16,'Scheduling control logic budget exceeded'
  old_rates={x['final']['active_style']:x['rates']['processed_fps'] for x in baseline['live_streams']}
  baseline_relative=str(baseline_path.relative_to(ROOT)).replace('\\','/')
  baseline_commit=subprocess.check_output(['git','log','-1','--format=%h','--',baseline_relative],cwd=ROOT,text=True).strip()
  result['optimization_baseline']=dict(commit=baseline_commit,path=baseline_relative,sha256=sha(baseline_path),
   resources=previous,resource_delta=deltas,
   processed_fps={x['final']['active_style']:{'before':old_rates[x['final']['active_style']],
    'after':x['rates']['processed_fps'],'improvement_percent':100*(x['rates']['processed_fps']/old_rates[x['final']['active_style']]-1)} for x in streams})
  assert all(x['rates']['processed_fps']>old_rates[x['final']['active_style']] for x in streams),'Frame rate did not improve'
  if compute_evidence:
   # Baseline was reprogrammed and sampled on this board before the change.
   # Three decoder layers execute 6,144 / 6,144 / 12,288 channel jobs.
   removed=(21+21+15)*(12*16*32+48*8*16+192*8*8)
   same_session={}
   for mode,style in [('style',True),('original',False)]:
    p=out/('baseline_'+mode+'.json')
    sample=json.loads(p.read_text()) if p.exists() else next(x for x in baseline['live_streams'] if x['final']['active_style']==style)
    assert sample['hardware_stream_pass'] and sample['bitstream_sha256']==baseline['bitstream_sha256']
    current=next(x for x in streams if x['final']['active_style']==style)
    before,after=sample['processing_sample'],current['processing_sample']
    assert before['compute_mhz']==after['compute_mhz'] and before['prefix_mac_cycles']-after['prefix_mac_cycles']==removed
    same_session[mode]=dict(source='same_session_short_test' if p.exists() else 'historical_60s_test',
     sha256=sha(p) if p.exists() else sha(baseline_path),processed_fps=sample['rates']['processed_fps'],
     busy_cycles_before=before['prefix_mac_cycles'],busy_cycles_after=after['prefix_mac_cycles'],removed_busy_cycles=removed)
   result['optimization_baseline']['busy_cycle_comparisons']=same_session
 (out/'verification.json').write_text(json.dumps(result,indent=2)+'\n')
 (record_path or ROOT/'docs/analysis/cyclegan_video_fps_optimization.json').write_text(json.dumps(result,indent=2)+'\n')
 print('VIDEO_DEPLOYMENT_PASS',flush=True)

if __name__=='__main__':
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--pair',type=Path,required=True);ap.add_argument('--record',action='store_true')
 ap.add_argument('--out',type=Path,default=ROOT/'build/video_verified');ap.add_argument('--physical-confirmation')
 ap.add_argument('--record-path',type=Path,default=ROOT/'docs/analysis/cyclegan_video_fps_optimization.json')
 ap.add_argument('--baseline',type=Path,default=ROOT/'docs/analysis/cyclegan_video_deployment.json');args=ap.parse_args()
 if args.record:record(args.out.resolve(),args.pair.resolve(),args.physical_confirmation,args.record_path,args.baseline)
 else:pair_check(args.pair.resolve())
