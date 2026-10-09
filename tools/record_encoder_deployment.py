"""Require matching bitstream/source hashes, board results and routed timing."""
from pathlib import Path
import argparse,hashlib,json,re,tempfile
from datetime import datetime,timezone

ROOT=Path(__file__).resolve().parents[1]
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
 cli=argparse.ArgumentParser();cli.add_argument('--project',type=Path);args=cli.parse_args()
 project=args.project or Path((ROOT/'build/stage1/staging_path.txt').read_text().strip())
 flow=project/'outflow';manifest=json.loads((project/'source_manifest.json').read_text())
 for name,digest in manifest['rtl_sha256'].items():
  assert sha(ROOT/'rtl'/name)==digest,(name,'source changed after build')
 result=json.loads((ROOT/'build/stage1/board_result.json').read_text())
 assert result['bitstream_sha256']==sha(flow/'encoder_board.bit')
 assert result['sources']==manifest
 assert len(result['frames'])>=2
 assert all(f['mismatches']==0 and f['values']==38400 and f['command_wait_cycles']==0 and f['input_checksum']==f['expected_input_checksum'] for f in result['frames'])
 mapping=(flow/'encoder_board.map.rpt').read_text();timing=(flow/'encoder_board.timing.rpt').read_text()
 resources={name:int(re.search(r'^'+name+r'\s*:\s*(\d+)',mapping,re.M)[1]) for name in ['EFX_LUT4','EFX_FF','EFX_RAM10','EFX_DPRAM10','EFX_DSP48']}
 optional=re.search(r'^EFX_DSP24\s*:\s*(\d+)',mapping,re.M);resources['EFX_DSP24']=int(optional[1]) if optional else 0
 resources['BRAM_total']=resources['EFX_RAM10']+resources['EFX_DPRAM10']
 sections=[timing.split('Setup (Max) Clock Relationship')[1].split('Hold (Min)')[0],timing.split('Hold (Min) Clock Relationship')[1].split('NOTE:')[0]]
 paths=[]
 for kind,section in zip(('setup','hold'),sections):
  for line in section.splitlines():
   m=re.match(r'\s*(\w+)\s+(\w+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s+\(',line)
   if m:paths.append(dict(kind=kind,launch=m[1],capture=m[2],slack_ns=float(m[4])))
 assert paths and all(p['slack_ns']>=0 for p in paths),paths
 native={}
 for suffix in ('','_inverted','_delay45'):
  log=ROOT/f'build/stage1/native{suffix}.log';text=log.read_text(errors='replace')
  assert 'PASS stage1:' in text,log
  # Match the completed transcript to its isolated, actually compiled sources.
  matches=[p.parent for p in Path(tempfile.gettempdir()).glob('encoder_sim_*/encoder_native.log') if sha(p)==sha(log)]
  assert len(matches)==1,('Missing or ambiguous native simulation staging',log)
  source_hashes={name:sha(matches[0]/name) for name in manifest['rtl_sha256'] if name not in ('mn_model_rom.sv','cyclegan_ddr_read_bridge.sv')}
  assert all(digest==manifest['rtl_sha256'][name] for name,digest in source_hashes.items()),('Stale native simulation',log)
  native[suffix or 'normal']=dict(sha256=sha(log),summary=re.search(r'PASS stage1:.*',text)[0],
   rtl_sha256=source_hashes,testbench_sha256=sha(matches[0]/'tb_cyclegan_encoder.sv'))
 regression={}
 bridge_log=ROOT/'build/stage1/ddr_bridge.log';bridge_text=bridge_log.read_text()
 assert 'PASS DDR bridge:' in bridge_text
 regression['ddr_bridge']=dict(sha256=sha(bridge_log),summary=re.search(r'PASS DDR bridge:.*',bridge_text)[0],
  source_sha256=sha(ROOT/'rtl/cyclegan_ddr_read_bridge.sv'),testbench_sha256=sha(ROOT/'sim/tb_cyclegan_ddr_read_bridge.sv'))
 for name in ('unit.log','bus.log'):
  log=ROOT/'build/sim'/name
  text=log.read_text(errors='replace');assert 'PASS' in text,log
  regression[name]=dict(sha256=sha(log),summaries=re.findall(r'PASS[^\r\n]*',text))
 record=dict(recorded_utc=datetime.now(timezone.utc).isoformat(),stage=1,target='RGB -> encoder3 -> residual input',
  checkpoint_sha256=json.loads((ROOT/'build/cyclegan_model/params_manifest.json').read_text())['checkpoint_sha256'],
  resources=resources,timing=paths,board=result,native_simulation=native,regression=regression,
  reports={p.name:sha(p) for p in [flow/'encoder_board.map.rpt',flow/'encoder_board.timing.rpt',flow/'encoder_board.place.rpt']})
 primary=ROOT/'build/stage1/board_primary_result.json'
 if primary.exists():
  first=json.loads(primary.read_text())
  if first['bitstream_sha256']==result['bitstream_sha256']:
   assert first['sources']==manifest
   assert all(f['mismatches']==0 and f['input_checksum']==f['expected_input_checksum'] and f['ddr_verified'] for f in first['frames'])
   record['first_boot_board']=first
 baseline=ROOT/'build/stage1/board_baseline_result.json'
 if baseline.exists():record['before_column_prefetch']=json.loads(baseline.read_text())
 failures=[]
 for path in sorted((ROOT/'build/stage1').glob('board_failed*_result.json')):
  failed=json.loads(path.read_text())
  failures.append(dict(file=path.name,sha256=sha(path),bitstream_sha256=failed['bitstream_sha256'],frames=failed['frames']))
 record['rejected_candidates']=failures
 out=ROOT/'docs/analysis/cyclegan_stage1_deployment.json';out.write_text(json.dumps(record,indent=2)+'\n')
 print('STAGE1_EVIDENCE_PASS',resources)
if __name__=='__main__':main()
