"""Archive successful validation summaries and current RTL/report hashes."""
import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def passed(path, pattern):
    path = ROOT / path
    match = re.search(pattern, path.read_text(encoding='utf-8-sig'))
    if match is None:
        raise RuntimeError(f'Missing successful validation: {path}')
    return {'log': path.relative_to(ROOT).as_posix(), 'sha256': sha(path),
            'summary': match.group(0)}


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--unit-log', default='build/sim/unit.log')
    cli.add_argument('--bus-log', default='build/sim/bus.log')
    args = cli.parse_args()
    reports = ROOT/'build/efinity/outflow'
    mapping = (reports/'mobilenet.map.rpt').read_text()
    if 'module cyclegan_bus_top' not in (reports/'mobilenet.map.v').read_text():
        raise RuntimeError('Current netlist is not the fixed CycleGAN top')
    number = lambda name: int(re.search(rf'{name}\s*:\s*(\d+)', mapping).group(1))
    resource = {name: number(name) for name in ('EFX_LUT4', 'EFX_FF', 'EFX_DSP48',
                                              'EFX_ADD', 'EFX_SRL8', 'EFX_RAM10', 'EFX_DPRAM10')}
    resource['BRAM_total'] = resource['EFX_RAM10']+resource['EFX_DPRAM10']
    timing = (reports/'mobilenet.timing.rpt').read_text()
    setup = float(re.search(r'Setup \(Max\).*?clk\s+clk\s+10\.000\s+([\d.-]+)', timing, re.S).group(1))
    hold = float(re.search(r'Hold \(Min\).*?clk\s+clk\s+0\.000\s+([\d.-]+)', timing, re.S).group(1))
    assert resource['BRAM_total'] <= 180 and setup >= 0 and hold >= 0
    with (ROOT/'build/sim/commands.csv').open() as stream:
        commands = list(csv.DictReader(stream))
    tests = {
        'core_rtl': passed(args.unit_log, r'PASS: \d+ cases, \d+ commands, \d+ cycles'),
        'bus_rtl': passed(args.bus_log, r'PASS bus:[^\r\n]+'),
        'model_assets_rtl': passed('build/sim/assets.log', r'PASS assets:[^\r\n]+'),
        'model_bus_rtl': passed('build/sim/model_bus.log', r'PASS epoch11 bus:[^\r\n]+'),
        'model_bus_mapped': passed('build/sim/model_postmap.log', r'PASS epoch11 bus:[^\r\n]+'),
        'postprocess_rtl': passed('build/sim/postprocess.log', r'PASS serial postprocess:[^\r\n]+'),
    }
    cases, count, cycles = [int(x) for x in re.findall(r'\d+', tests['core_rtl']['summary'])]
    assert len(commands) == count and max(int(x['case']) for x in commands) == cases
    tests['core_rtl'].update(cases=cases, commands=count, cycles=cycles,
                             expected_error_commands=sum(int(x['error']) != 0 for x in commands))
    frames = []
    for suffix in ('', '_inverted'):
        path = ROOT/f'build/cyclegan_schedule/validation{suffix}.json'
        frame = json.loads(path.read_text())
        assert frame['all_layers_equal'] and frame['layers_checked'] == 16
        assert frame['final_values_checked'] == 230400
        frame['input'] = 'test.jpg' if not suffix else 'inverted test.jpg'
        frames.append(frame)
    files = sorted((ROOT/'rtl').glob('*.sv')) + [ROOT/'rtl/mn_isa.vh',
             ROOT/'rtl/mn_model_params_init.vh', ROOT/'rtl/mn_tanh_u8.mem']
    result = {'recorded_utc': datetime.now(timezone.utc).isoformat(),
              'baseline_git_commit': '820a5df', 'top': 'cyclegan_bus_top',
              'device': 'Ti60F225', 'efinity': '2026.1.132', 'timing_model': 'C4',
              'synthesis_resources': resource,
              'internal_timing': {'target_mhz': 100, 'setup_slack_ns': setup,
                                  'hold_slack_ns': hold, 'board_io_constrained': False},
              'tests': tests, 'full_network_instruction_model': frames,
              'host_protocol': {'row_commits_checked': 70, 'addresses_checked': 7,
                                'scope': 'Python protocol model; separate RTL bus tests'},
              'limitations': ['host keeps full feature maps and interleaves transpose phases',
                              'no board transport, DDR DMA or autonomous FPGA layer scheduler',
                              'no full-frame RTL simulation or on-board inference validation'],
              'rtl_sha256': {p.relative_to(ROOT).as_posix(): sha(p) for p in files},
              'report_sha256': {p.name: sha(p) for p in [reports/'mobilenet.map.rpt',
                                                       reports/'mobilenet.timing.rpt',
                                                       reports/'mobilenet.place.rpt']}}
    target = ROOT/'docs/analysis/cyclegan_iteration1_results.json'
    target.write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print('RESULTS_RECORDED', cases, 'cases,', count, 'commands,', resource['BRAM_total'], 'BRAM')


if __name__ == '__main__':
    main()
