"""Commit evidence only for matching sources, native simulation and two board boots."""
from pathlib import Path
import argparse,hashlib,json,re,tempfile
from datetime import datetime,timezone
from record_encoder_deployment import ROOT,sha

def main():
 ap=argparse.ArgumentParser();ap.add_argument('--out',type=Path,default=ROOT/'build/stage2')
 ap.add_argument('--optimization',action='store_true');args=ap.parse_args()
 out=args.out;project=Path((out/'staging_path.txt').read_text().strip());flow=project/'outflow'
 prior=json.loads((ROOT/'docs/analysis/cyclegan_stage2_deployment.json').read_text()) if args.optimization else None
 regression_out=ROOT/'build/stage2' if args.optimization else out
 manifest=json.loads((project/'source_manifest.json').read_text())
 for name,digest in manifest['rtl_sha256'].items():assert sha(ROOT/'rtl'/name)==digest,(name,'source changed after build')
 boots=[]
 for file,count in [('board_primary_result.json',2),('board_result.json',4)]:
  result=json.loads((out/file).read_text())
  assert result.get('failure') is None
  assert result['bitstream_sha256']==sha(flow/'encoder_board.bit') and result['sources']==manifest
  assert len(result['frames'])==count
  for f in result['frames']:
   assert f['phy_phase']==6
   assert f['input_checksum']==f['expected_input_checksum'] and f['command_wait_cycles']==0 and f['blocks_completed']==9
   assert f['mismatches']==0
   blocks=f['blocks'];assert len(blocks)==(9 if f['mode']=='block_readback' else 1)
   assert [b['block'] for b in blocks]==(list(range(1,10)) if len(blocks)==9 else [9])
   for b in blocks:
    assert b['values']==38400 and b['mismatches']==0 and b['expected_sha256']==b['actual_sha256']
    assert b['cycles']==49155 and b['cumulative_cycles']==b['block']*49155
   assert f['residual_cycles']==442395
  boots.append(result)
 assert all(f['ddr_verified'] and len(f['blocks'])==9 for f in boots[0]['frames'])
 assert [f['mode'] for f in boots[1]['frames']]==['block_readback']*2+['continuous']*2
 mapping=(flow/'encoder_board.map.rpt').read_text();timing=(flow/'encoder_board.timing.rpt').read_text()
 resources={name:int(re.search(r'^'+name+r'\s*:\s*(\d+)',mapping,re.M)[1]) for name in ['EFX_LUT4','EFX_FF','EFX_RAM10','EFX_DPRAM10','EFX_DSP48']}
 optional=re.search(r'^EFX_DSP24\s*:\s*(\d+)',mapping,re.M);resources['EFX_DSP24']=int(optional[1]) if optional else 0
 resources['BRAM_total']=resources['EFX_RAM10']+resources['EFX_DPRAM10']
 assert resources['EFX_DSP48']==100 and resources['EFX_DSP24']==0 and resources['BRAM_total']<=256
 paths=[]
 sections=[timing.split('Setup (Max) Clock Relationship')[1].split('Hold (Min)')[0],timing.split('Hold (Min) Clock Relationship')[1].split('NOTE:')[0]]
 for kind,section in zip(('setup','hold'),sections):
  for line in section.splitlines():
   m=re.match(r'\s*(\w+)\s+(\w+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+\(',line)
   if m:paths.append(dict(kind=kind,launch=m[1],capture=m[2],slack_ns=float(m[4])))
 assert paths and all(p['slack_ns']>=0 for p in paths)
 native={}
 for suffix in ('','_inverted','_delay45'):
  log=out/f'native{suffix}.log';text=log.read_text(errors='replace');assert 'PASS stage2:' in text
  matches=[p.parent for p in Path(tempfile.gettempdir()).glob('residual_sim_*/residual_native.log') if sha(p)==sha(log)]
  assert len(matches)==1,('Missing native staging',log)
  hashes={name:sha(matches[0]/name) for name in manifest['rtl_sha256'] if name not in ('mn_model_rom.sv','cyclegan_ddr_read_bridge.sv')}
  assert all(digest==manifest['rtl_sha256'][name] for name,digest in hashes.items()),('Stale native simulation',log)
  assert sha(matches[0]/'tb_cyclegan_residual.sv')==sha(ROOT/'sim/tb_cyclegan_residual.sv')
  native[suffix or 'normal']=dict(sha256=sha(log),summary=re.search(r'PASS stage2:.*',text)[0],rtl_sha256=hashes,
   testbench_sha256=sha(matches[0]/'tb_cyclegan_residual.sv'))
 regression={}
 log=regression_out/'ddr_bridge_0.log';text=log.read_text();assert 'PASS DDR bridge:' in text
 regression['ddr_bridge']=dict(sha256=sha(log),summary=re.search(r'PASS DDR bridge:.*',text)[0],
  source_sha256=sha(ROOT/'rtl/cyclegan_ddr_read_bridge.sv'),testbench_sha256=sha(ROOT/'sim/tb_cyclegan_ddr_read_bridge.sv'))
 unit_project=Path((regression_out/'unit_staging_path.txt').read_text().strip())
 unit_hashes={name:sha(unit_project/name) for name in manifest['rtl_sha256'] if (unit_project/name).exists()}
 assert all(digest==manifest['rtl_sha256'][name] for name,digest in unit_hashes.items())
 assert sha(unit_project/'mobilenet_bus_top.sv')==sha(ROOT/'rtl/mobilenet_bus_top.sv')
 for bench in ('tb_mobilenet_unit.sv','tb_mobilenet_bus.sv'):
  assert sha(unit_project/bench)==sha(ROOT/'sim'/bench)
 for name in ('unit.log','bus.log'):
  log=ROOT/'build/sim'/name;text=log.read_text(errors='replace');assert 'PASS' in text
  assert sha(log)==sha(unit_project/name)
  regression[name]=dict(sha256=sha(log),summaries=re.findall(r'PASS[^\r\n]*',text),rtl_sha256=unit_hashes)
 record=dict(recorded_utc=datetime.now(timezone.utc).isoformat(),stage=2,target='RGB -> encoder3 -> nine residual blocks',
  parent_commit='c31d0db' if args.optimization else '397a3cd',checkpoint_sha256=json.loads((ROOT/'build/cyclegan_model/params_manifest.json').read_text())['checkpoint_sha256'],
  resources=resources,timing=paths,board_boots=boots,native_simulation=native,regression=regression,
  rom=json.loads((regression_out/'rom_layout.json').read_text()),
  reports={p.name:sha(p) for p in [flow/'encoder_board.map.rpt',flow/'encoder_board.timing.rpt',flow/'encoder_board.place.rpt']},
  shell_sha256={name:sha(project/name) for name in ('cyclegan_encoder_board.v','debug_profile.json','encoder_board.sdc')})
 record['rejected_candidates']=[dict(file=p.name,sha256=sha(p),result=json.loads(p.read_text())) for p in sorted(out.glob('board_failed*_result.json'))]
 control_file=out/'board_phase5_control_result.json'
 control=json.loads((control_file if control_file.exists() else out/'board_failed_phase5_result.json').read_text())
 assert control['bitstream_sha256']==sha(flow/'encoder_board.bit')
 if control['failure']:
  assert control['failure']['state']['phy_phase']==5 and control['failure']['state']['input_checksum']!=846017256
 else:
  assert len(control['frames'])==1
  frame=control['frames'][0]
  assert frame['phy_phase']==5 and frame['input_checksum']==frame['expected_input_checksum'] and frame['mismatches']==0
  assert all(b['actual_sha256']==b['expected_sha256'] for b in frame['blocks'])
 record['sampling_phase_control']=dict(bitstream_sha256=control['bitstream_sha256'],phase5_failure=control['failure'],phase5_frames=control['frames'],
  phase6_same_boot_frame_ids=[f['frame_id'] for f in boots[0]['frames']],
  phase6_reprogrammed_frame_ids=[f['frame_id'] for f in boots[1]['frames']])
 if args.optimization:
  old_manifest=prior['board_boots'][0]['sources']['rtl_sha256']
  changed=[name for name,digest in manifest['rtl_sha256'].items() if old_manifest.get(name)!=digest]
  assert sorted(changed)==['cyclegan_encoder.sv','cyclegan_residual_scheduler.sv']
  assert regression['ddr_bridge']==prior['regression']['ddr_bridge']
  assert all(native[k]['summary']==prior['native_simulation'][k]['summary'] for k in native)
  previous_values={(f['input_variant'],b['block']):b['actual_sha256'] for boot in prior['board_boots'] for f in boot['frames'] for b in f['blocks']}
  assert all(b['actual_sha256']==previous_values[(f['input_variant'],b['block'])] for boot in boots for f in boot['frames'] for b in f['blocks'])
  assert resources['EFX_LUT4']<prior['resources']['EFX_LUT4'] and resources['EFX_FF']<prior['resources']['EFX_FF']
  assert resources['BRAM_total']==prior['resources']['BRAM_total']
  profile=json.loads((project/'debug_profile.json').read_text())
  assert [p['name'] for p in profile['debug_cores'][0]['probes']]==['status','read_data0','read_data1','read_data2','read_data3','command','payload0','payload1']
  record['optimization']=dict(baseline_commit='c31d0db',baseline_evidence_sha256=sha(ROOT/'docs/analysis/cyclegan_stage2_deployment.json'),
   before_resources=prior['resources'],saved_resources={k:prior['resources'][k]-v for k,v in resources.items()},
   arithmetic_sources_unchanged=True,changed_rtl=changed,native_summaries_identical=True,board_block_hashes_identical=True,
   vio_input_bits=832,previous_vio_input_bits=1248,mailbox_statistics_word_bits=32,removed_duplicate_mailbox_ff=800)
  record['optimization']['first_stage_resources']=json.loads((ROOT/'docs/analysis/cyclegan_stage1_deployment.json').read_text())['resources']
  if not control['failure']:record['optimization']['phase_control_observation']='Phase 5 passed on this changed placement; keep phase 6 for the six-frame deployment gate. Prior-bitstream negative control remains historical evidence.'
  record['tool_sha256']={str(p.relative_to(ROOT)):sha(p) for p in [ROOT/'tools'/name for name in
   ('prepare_encoder_deployment.py','prepare_residual_deployment.py','debug_encoder_deployment.py',
    'debug_residual_deployment.py','record_residual_deployment.py')]+[ROOT/'scripts'/name for name in
   ('run_residual_modelsim.ps1','run_residual_board.ps1')]}
  record['reports']['encoder_board.hier_util.rpt']=sha(flow/'encoder_board.hier_util.rpt')
  record['shell_sha256']['debug_top.v']=sha(project/'debug_top.v')
  candidate=ROOT/'build/stage2_opt/staging_path.txt'
  if candidate.exists():
   candidate_path=Path(candidate.read_text().strip());mapping_a=(candidate_path/'outflow/encoder_board.map.rpt').read_text()
   record['optimization']['rejected_wide_statistics_mux']=dict(project=str(candidate_path),
    resources={name:int(re.search(r'^'+name+r'\s*:\s*(\d+)',mapping_a,re.M)[1]) for name in ('EFX_LUT4','EFX_FF')},
    reason='416-bit statistics mux reduced FF but increased LUT; replaced by indexed 32-bit reads',
    map_report_sha256=sha(candidate_path/'outflow/encoder_board.map.rpt'))
  candidate_b=ROOT/'build/stage2_resource_opt/staging_path.txt'
  if candidate_b.exists():
   candidate_path=Path(candidate_b.read_text().strip());mapping_b=(candidate_path/'outflow/encoder_board.map.rpt').read_text()
   record['optimization']['rejected_full_word_clear']=dict(project=str(candidate_path),
    resources={name:int(re.search(r'^'+name+r'\s*:\s*(\d+)',mapping_b,re.M)[1]) for name in ('EFX_LUT4','EFX_FF')},
    reason='Clearing 768 unused reply bits introduced a wide extra mux; retain those bits on statistics reads',
    map_report_sha256=sha(candidate_path/'outflow/encoder_board.map.rpt'))
  candidate_c=ROOT/'build/stage2_resource_final/staging_path.txt'
  if candidate_c.exists():
   candidate_path=Path(candidate_c.read_text().strip());mapping_c=(candidate_path/'outflow/encoder_board.map.rpt').read_text()
   record['optimization']['before_counter_and_address_consolidation']=dict(project=str(candidate_path),
    resources={name:int(re.search(r'^'+name+r'\s*:\s*(\d+)',mapping_c,re.M)[1]) for name in ('EFX_LUT4','EFX_FF')},
    map_report_sha256=sha(candidate_path/'outflow/encoder_board.map.rpt'))
  destination=ROOT/'docs/analysis/cyclegan_stage2_resource_optimization.json'
 else:destination=ROOT/'docs/analysis/cyclegan_stage2_deployment.json'
 destination.write_text(json.dumps(record,indent=2)+'\n',encoding='utf8')
 print('STAGE2_EVIDENCE_PASS',resources)
if __name__=='__main__':main()
