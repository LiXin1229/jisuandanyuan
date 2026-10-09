"""Record stage-3 evidence only after matching RTL, timing and two board boots."""
from pathlib import Path
import argparse,hashlib,json,re
from datetime import datetime,timezone
ROOT=Path(__file__).resolve().parents[1]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--out',type=Path,default=ROOT/'build/stage3_verified');args=ap.parse_args()
 out=args.out;project=Path((out/'staging_path.txt').read_text().strip());flow=project/'outflow'
 manifest=json.loads((project/'source_manifest.json').read_text())
 for name,digest in manifest['rtl_sha256'].items():assert sha(ROOT/'rtl'/name)==digest,(name,'stale board build')
 boots=[]
 for boot in ('primary','repeat'):
  result=json.loads((out/f'board_{boot}_result.json').read_text())
  assert result['failure'] is None and result['sources']==manifest and result['bitstream_sha256']==sha(flow/'encoder_board.bit')
  assert len(result['frames'])==2
  for i,f in enumerate(result['frames']):
   assert f['input_checksum']==f['expected_input_checksum']==(4194243663 if i else 846017256)
   assert f['phy_phase']==6 and f['blocks_completed']==9 and f['layers_completed']==3 and f['command_wait_cycles']==0
   assert f['residual_cycles']==442395 and f['chunks']==4799 and f['mismatches']==0
   assert f['frame_id']==i and f['frames']==i+1
   assert [b['block'] for b in f['blocks']]==(list(range(1,10)) if boot=='primary' else [])
   assert [b['layer'] for b in f['layers']]==([1,2,3] if boot=='primary' else [3])
   assert f['mode']==('layer_readback' if boot=='primary' else 'continuous')
   assert f['ddr_verified']==(boot=='primary')
   for check in f['blocks']+f['layers']:
    assert check['mismatches']==0 and check['expected_sha256']==check['actual_sha256']
    assert check['values']==(38400 if 'block' in check else {1:76800,2:153600,3:614400}[check['layer']])
   if boot=='primary':assert f['decoder_cycles']==sum(b['cycles'] for b in f['layers'])
  program=(out/f'program_{boot}.log').read_text()
  assert '0x10660A79' in program and 'finished with JTAG programming' in program
  boots.append(result)
 for i in range(2):assert boots[0]['frames'][i]['layers'][-1]['actual_sha256']==boots[1]['frames'][i]['layers'][0]['actual_sha256']
 mapping=(flow/'encoder_board.map.rpt').read_text();timing=(flow/'encoder_board.timing.rpt').read_text()
 resources={name:int(re.search(r'^'+name+r'\s*:\s*(\d+)',mapping,re.M)[1]) for name in ('EFX_LUT4','EFX_FF','EFX_RAM10','EFX_DPRAM10','EFX_DSP48')}
 m=re.search(r'^EFX_DSP24\s*:\s*(\d+)',mapping,re.M);resources['EFX_DSP24']=int(m[1]) if m else 0
 resources['BRAM_total']=resources['EFX_RAM10']+resources['EFX_DPRAM10']
 assert resources['EFX_DSP48']==100 and resources['EFX_DSP24']==0 and resources['BRAM_total']==218
 paths=[]
 for kind,section in zip(('setup','hold'),(timing.split('Setup (Max) Clock Relationship')[1].split('Hold (Min)')[0],timing.split('Hold (Min) Clock Relationship')[1].split('NOTE:')[0])):
  for line in section.splitlines():
   m=re.match(r'\s*(\w+)\s+(\w+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+\(',line)
   if m:paths.append(dict(kind=kind,launch=m[1],capture=m[2],slack_ns=float(m[4])))
 assert paths and all(p['slack_ns']>=0 for p in paths)
 native={}
 for suffix,full in (('',1),('_inverted_delay45',0)):
  log=out/f'native{suffix}.log';text=log.read_text(errors='replace')
  assert 'PASS stage3:' in text and 'Errors: 0' in text and '** Fatal:' not in text
  summary=re.search(r'PASS stage3:.*',text)[0]
  assert f'full_prefix={full}' in summary and 'values=844800' in summary and 'command_wait=0' in summary
  assert f'commands={152448 if full else 106752}' in summary
  stage=Path((out/f'native{suffix}_path.txt').read_text().strip())
  hashes={name:sha(stage/name) for name in manifest['rtl_sha256'] if (stage/name).exists()}
  assert all(digest==manifest['rtl_sha256'][name] for name,digest in hashes.items())
  assert sha(stage/'mn_isa.vh')==sha(ROOT/'rtl/mn_isa.vh')
  assert sha(stage/'tb_cyclegan_decoder.sv')==sha(ROOT/'sim/tb_cyclegan_decoder.sv')
  native[suffix or 'full_prefix']=dict(summary=summary,sha256=sha(log),rtl_sha256=hashes,testbench_sha256=sha(stage/'tb_cyclegan_decoder.sv'))
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
 prior=json.loads((ROOT/'docs/analysis/cyclegan_stage2_resource_optimization.json').read_text())
 for name in ('mn_pe_array.sv','mn_compact.sv','mn_postprocess.sv','mn_cache.sv','mn_dw_buffer_bram.sv','mn_input_mux.sv','cyclegan_residual_scheduler.sv'):
  assert manifest['rtl_sha256'][name]==prior['board_boots'][0]['sources']['rtl_sha256'][name]
 record=dict(recorded_utc=datetime.now(timezone.utc).isoformat(),stage=3,parent_commit='c8683d8',
  target='RGB 3x240x320 -> encoder -> nine residuals -> three transpose convolutions -> Q4.4 8x240x320',
  checkpoint_sha256=json.loads((ROOT/'build/cyclegan_model/params_manifest.json').read_text())['checkpoint_sha256'],
  resources=resources,resource_change={k:v-prior['resources'][k] for k,v in resources.items()},timing=paths,
  board_boots=boots,native_simulation=native,regression=regression,rom=json.loads((ROOT/'build/stage3/rom_layout.json').read_text()),
  ddr_layout=dict(tile_bytes=128,half_bytes=64,half_payload_bytes=50,channel_major=True,bases=[0x300000,0x400000,0x500000]),
  cache_layout=dict(input_ring=[512,895],phase_slots=[1424,1431],interleave_slots=[1432,1439]),
  verification_values=sum(f['values'] for boot in boots for f in boot['frames']),
  reports={p.name:sha(p) for p in (flow/'encoder_board.map.rpt',flow/'encoder_board.timing.rpt',flow/'encoder_board.place.rpt',flow/'encoder_board.hier_util.rpt')},
  shell_sha256={name:sha(project/name) for name in ('cyclegan_encoder_board.v','debug_profile.json','debug_top.v','encoder_board.sdc')},
  tool_sha256={str(p.relative_to(ROOT)):sha(p) for p in [ROOT/'tools'/n for n in ('prepare_decoder_deployment.py','prepare_encoder_deployment.py','debug_decoder_deployment.py','record_decoder_deployment.py')]+[ROOT/'scripts'/n for n in ('run_decoder_modelsim.ps1','run_decoder_board.ps1')]})
 failed=ROOT/'build/stage3/board_result.json'
 if failed.exists():
  candidate=json.loads(failed.read_text())
  if candidate.get('failure'):record['integration_regression']=dict(failure=candidate['failure'],bitstream_sha256=candidate['bitstream_sha256'],source_sha256=sha(failed),cause='Encoder pooled writes at 1427/1431 must not advance an inactive decoder. Full-prefix simulation asserts decoder inactivity throughout encoder/residual stages.')
 dest=ROOT/'docs/analysis/cyclegan_stage3_deployment.json';dest.write_text(json.dumps(record,indent=2)+'\n',encoding='utf8')
 print('STAGE3_EVIDENCE_PASS',resources,'board_values',record['verification_values'])

if __name__=='__main__':main()
