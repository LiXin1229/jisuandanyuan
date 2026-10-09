"""Record stage-4 evidence only after matching RTL, timing and two board boots."""
from pathlib import Path
import argparse,hashlib,json,re
from datetime import datetime,timezone
ROOT=Path(__file__).resolve().parents[1]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--out',type=Path,default=ROOT/'build/stage4_verified');args=ap.parse_args()
 out=args.out;project=Path((out/'staging_path.txt').read_text().strip());flow=project/'outflow'
 manifest=json.loads((project/'source_manifest.json').read_text())
 for name,digest in manifest['rtl_sha256'].items():assert sha(ROOT/'rtl'/name)==digest,(name,'stale board build')
 assets={name:sha(project/name) for name in ('mn_isa.vh','mn_tanh_u8.mem')}
 for name,digest in assets.items():assert digest==sha(ROOT/'rtl'/name),(name,'stale board asset')
 model=json.loads((ROOT/'build/cyclegan_model/params_manifest.json').read_text())
 assert assets['mn_tanh_u8.mem']==model['tanh']['table_sha256']
 boots=[]
 for boot in ('primary','repeat'):
  result=json.loads((out/f'board_{boot}_result.json').read_text())
  assert result['failure'] is None and result['sources']==manifest and result['bitstream_sha256']==sha(flow/'encoder_board.bit')
  assert len(result['frames'])==2
  for i,f in enumerate(result['frames']):
   assert f['input_checksum']==f['expected_input_checksum']==(4194243663 if i else 846017256)
   assert f['output_completed'] and f['output_cycles']>0
   assert f['phy_phase']==6 and f['blocks_completed']==9 and f['layers_completed']==3 and f['command_wait_cycles']==0
   assert f['residual_cycles']==442395 and f['chunks']==4799 and f['mismatches']==0
   assert f['busy_cycles']==6375696
   assert f['frame_id']==i and f['frames']==i+1
   assert [b['block'] for b in f['blocks']]==(list(range(1,10)) if boot=='primary' else [])
   assert [b['layer'] for b in f['layers']]==([1,2,3,4] if boot=='primary' else [4])
   assert f['mode']==('layer_readback' if boot=='primary' else 'continuous')
   assert f['ddr_verified']==(boot=='primary')
   for check in f['blocks']+f['layers']:
    assert check['mismatches']==0 and check['expected_sha256']==check['actual_sha256']
    assert check['values']==(38400 if 'block' in check else {1:76800,2:153600,3:614400,4:230400}[check['layer']])
   if boot=='primary':assert f['decoder_cycles']==sum(b['cycles'] for b in f['layers'][:3])
   assert f['layers'][-1]['cycles']==f['output_cycles']
  program=(out/f'program_{boot}.log').read_text()
  assert '0x10660A79' in program and 'finished with JTAG programming' in program
  boots.append(result)
 for i in range(2):assert boots[0]['frames'][i]['layers'][-1]['actual_sha256']==boots[1]['frames'][i]['layers'][0]['actual_sha256']
 import numpy as np
 from PIL import Image
 images={}
 for suffix in ('','_inverted'):
  path=out/f'board_output{suffix}.png'
  actual=np.asarray(Image.open(path))
  expected=np.load(ROOT/('build/cyclegan_model/vectors'+suffix)/'output_u8.npy').transpose(1,2,0)
  assert actual.shape==(240,320,3) and np.array_equal(actual,expected)
  images[suffix or 'normal']=dict(path=str(path.relative_to(ROOT)),sha256=sha(path),rgb_sha256=hashlib.sha256(actual.tobytes()).hexdigest())
 mapping=(flow/'encoder_board.map.rpt').read_text();timing=(flow/'encoder_board.timing.rpt').read_text()
 resources={name:int(re.search(r'^'+name+r'\s*:\s*(\d+)',mapping,re.M)[1]) for name in ('EFX_LUT4','EFX_FF','EFX_RAM10','EFX_DPRAM10','EFX_DSP48')}
 m=re.search(r'^EFX_DSP24\s*:\s*(\d+)',mapping,re.M);resources['EFX_DSP24']=int(m[1]) if m else 0
 resources['BRAM_total']=resources['EFX_RAM10']+resources['EFX_DPRAM10']
 assert resources['EFX_DSP48']==100 and resources['EFX_DSP24']==0 and resources['BRAM_total']==222
 paths=[]
 for kind,section in zip(('setup','hold'),(timing.split('Setup (Max) Clock Relationship')[1].split('Hold (Min)')[0],timing.split('Hold (Min) Clock Relationship')[1].split('NOTE:')[0])):
  for line in section.splitlines():
   m=re.match(r'\s*(\w+)\s+(\w+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+\(',line)
   if m:paths.append(dict(kind=kind,launch=m[1],capture=m[2],slack_ns=float(m[4])))
 assert paths and all(p['slack_ns']>=0 for p in paths)
 native={}
 for suffix,full in (('',1),('_inverted_delay45',0)):
  log=out/f'native{suffix}.log';text=log.read_text(errors='replace')
  assert 'PASS stage4:' in text and 'Errors: 0' in text and '** Fatal:' not in text
  summary=re.search(r'PASS stage4:.*',text)[0]
  assert f'full_prefix={full}' in summary and f'values={1075200 if full else 230400}' in summary and 'command_wait=0' in summary
  assert f'commands={170880 if full else 18432}' in summary
  stage=Path((out/f'native{suffix}_path.txt').read_text().strip())
  hashes={name:sha(stage/name) for name in manifest['rtl_sha256'] if (stage/name).exists()}
  assert all(digest==manifest['rtl_sha256'][name] for name,digest in hashes.items())
  assert sha(stage/'mn_isa.vh')==sha(ROOT/'rtl/mn_isa.vh')
  assert sha(stage/'rtl/mn_tanh_u8.mem')==assets['mn_tanh_u8.mem']
  assert sha(stage/'tb_cyclegan_output.sv')==sha(ROOT/'sim/tb_cyclegan_output.sv')
  native[suffix or 'full_prefix']=dict(summary=summary,sha256=sha(log),rtl_sha256=hashes,testbench_sha256=sha(stage/'tb_cyclegan_output.sv'))
 regression={}
 unit_stage=Path((ROOT/'build/stage2/unit_staging_path.txt').read_text().strip())
 for name in ('unit.log','bus.log'):
  log=ROOT/'build/sim'/name;text=log.read_text(errors='replace')
  assert 'PASS' in text and 'Errors: 0' in text and sha(log)==sha(unit_stage/name)
  regression[name]=dict(sha256=sha(log),summaries=re.findall(r'PASS[^\r\n]*',text))
 for name in manifest['rtl_sha256']:
  if (unit_stage/name).exists():assert sha(unit_stage/name)==manifest['rtl_sha256'][name]
 arbiter=ROOT/'build/stage3/arbiter.log';assert 'PASS write arbiter:' in arbiter.read_text()
 regression['write_arbiter']=dict(sha256=sha(arbiter),summary=arbiter.read_text().splitlines()[0],rtl_sha256=sha(ROOT/'rtl/cyclegan_write_arbiter.sv'),testbench_sha256=sha(ROOT/'sim/tb_cyclegan_write_arbiter.sv'))
 prior=json.loads((ROOT/'docs/analysis/cyclegan_stage3_deployment.json').read_text())
 assert regression['write_arbiter']['sha256']==prior['regression']['write_arbiter']['sha256']
 assert regression['write_arbiter']['rtl_sha256']==prior['regression']['write_arbiter']['rtl_sha256']
 assert regression['write_arbiter']['testbench_sha256']==prior['regression']['write_arbiter']['testbench_sha256']
 for name in ('mn_pe_array.sv','mn_compact.sv','mn_postprocess.sv','mn_cache.sv','mn_dw_buffer_bram.sv','mn_input_mux.sv','cyclegan_residual_scheduler.sv'):
  assert manifest['rtl_sha256'][name]==prior['board_boots'][0]['sources']['rtl_sha256'][name]
 baseline_path=ROOT/'build/stage4_slot_co/comparison.json'
 baseline=json.loads(baseline_path.read_text()) if baseline_path.exists() else None
 comparison=None
 if baseline:
  old=int(re.search(r'output_cycles=(\d+)',baseline['summary'])[1])
  new=int(re.search(r'output_cycles=(\d+)',native['_inverted_delay45']['summary'])[1])
  assert new<old
  baseline_stage=Path((ROOT/'build/stage4_slot_co/native_inverted_delay45_path.txt').read_text().strip())
  baseline_rtl={name:sha(baseline_stage/name) for name in manifest['rtl_sha256'] if (baseline_stage/name).exists()}
  assert all(digest==manifest['rtl_sha256'][name] for name,digest in baseline_rtl.items() if name!='cyclegan_decoder_scheduler.sv')
  baseline['rtl_sha256']=baseline_rtl
  baseline['testbench_sha256']=sha(baseline_stage/'tb_cyclegan_output.sv')
  comparison=dict(scenario='Focused inverted output, DDR delay 45, continuous; native RTL simulation',
   baseline=baseline,optimized_cycles=new,saved_cycles=old-new,reduction_percent=(old-new)*100/old)
 record=dict(recorded_utc=datetime.now(timezone.utc).isoformat(),stage=4,parent_commit='09f6340',
  target='RGB 3x240x320 -> encoder -> nine residuals -> three transpose convolutions -> 7x7/Tanh -> uint8 RGB 3x240x320',
  checkpoint_sha256=model['checkpoint_sha256'],asset_sha256=assets,
  resources=resources,resource_change={k:v-prior['resources'][k] for k,v in resources.items()},timing=paths,
  board_boots=boots,native_simulation=native,regression=regression,images=images,scheduling_comparison=comparison,rom=json.loads((ROOT/'build/stage4/rom_layout.json').read_text()),
  ddr_layout=dict(tile_bytes=128,half_bytes=64,half_payload_bytes=50,channel_major=True,bases=[0x300000,0x400000,0x500000,0x600000]),
  cache_layout=dict(transpose_input_ring=[512,895],output_input_ring=[0,1023],output_slots=[1424,1428],phase_slots=[1424,1431],interleave_slots=[1432,1439]),
  verification_values=sum(f['values'] for boot in boots for f in boot['frames']),
  reports={p.name:sha(p) for p in (flow/'encoder_board.map.rpt',flow/'encoder_board.timing.rpt',flow/'encoder_board.place.rpt',flow/'encoder_board.hier_util.rpt')},
  shell_sha256={name:sha(project/name) for name in ('cyclegan_encoder_board.v','debug_profile.json','debug_top.v','encoder_board.sdc')},
  tool_sha256={str(p.relative_to(ROOT)):sha(p) for p in [ROOT/'tools'/n for n in ('prepare_output_deployment.py','prepare_encoder_deployment.py','debug_output_deployment.py','record_output_deployment.py')]+[ROOT/'scripts'/n for n in ('run_output_modelsim.ps1','run_output_board.ps1')]})
 dest=ROOT/'docs/analysis/cyclegan_stage4_deployment.json';dest.write_text(json.dumps(record,indent=2)+'\n',encoding='utf8')
 print('STAGE4_EVIDENCE_PASS',resources,'board_values',record['verification_values'])

if __name__=='__main__':main()
