"""Archive successful validation summaries and current RTL/report hashes."""
import argparse
import csv
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
from check_timing import read_timing

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
    cli.add_argument('--metrics', type=Path, default=ROOT/'build/sim/commands.csv')
    cli.add_argument('--output', type=Path, default=ROOT/'docs/analysis/cyclegan_iteration9_results.json')
    cli.add_argument('--baseline', default='857e566')
    cli.add_argument('--timing-trial-directory', type=Path, action='append', default=[])
    cli.add_argument('--bram-budget', type=int, default=200)
    args = cli.parse_args()
    reports = ROOT/'build/efinity/outflow'
    stage = Path((ROOT/'build/efinity/staging_path.txt').read_text().strip())
    for staged in (stage/'rtl').iterdir():
        if sha(staged) != sha(ROOT/'rtl'/staged.name):
            raise RuntimeError(f'Netlist source does not match current RTL: {staged.name}')
    mapping = (reports/'mobilenet.map.rpt').read_text()
    netlist = (reports/'mobilenet.map.v').read_text()
    if 'module cyclegan_bus_top' not in netlist:
        raise RuntimeError('Current netlist is not the fixed CycleGAN top')
    input_masks = re.findall(r"defparam \\core/unit/input_mux/[^\n]+LUTMASK = 16'h([0-9a-f]{4});", netlist)
    assert len(input_masks) == 800
    assert {mask: input_masks.count(mask) for mask in set(input_masks)} == {'00ca': 600, '0fca': 100, 'f0ca': 100}
    compact_masks = re.findall(r"defparam \\core/unit/compact/[^\n]+LUTMASK = 16'h([0-9a-f]{4});", netlist)
    assert len(compact_masks) == 700
    assert {mask: compact_masks.count(mask) for mask in set(compact_masks)} == {'7ffe': 500, 'fffe': 100, 'effe': 100}
    cache_parameters = {}
    for name,value in (('READ_WIDTH_B','5'), ('WRITE_WIDTH_B','5'),
                       ('RESET_RAM_B','"SYNC"'), ('WRITE_MODE_B','"NO_CHANGE"')):
        matches = re.findall(r'defparam \\core/unit/cache/plane\[\d+\]\.ram \.'+name+r' = ([^;]+);', netlist)
        assert len(matches) == 160 and set(matches) == {value}
        cache_parameters[name] = value
    window_parameters = {}
    for name,value in (('READ_WIDTH_A','8'), ('READ_WIDTH_B','8'),
                       ('WRITE_MODE_A','"NO_CHANGE"'), ('WRITE_MODE_B','"NO_CHANGE"')):
        matches = re.findall(r'defparam \\core/unit/windows/bank\[\d+\]\.ram \.'+name+r' = ([^;]+);', netlist)
        assert len(matches) == 8 and set(matches) == {value}
        window_parameters[name] = value
    number = lambda name: int(re.search(rf'{name}\s*:\s*(\d+)', mapping).group(1))
    resource = {name: number(name) for name in ('EFX_LUT4', 'EFX_FF', 'EFX_DSP48',
                                              'EFX_ADD', 'EFX_SRL8', 'EFX_RAM10', 'EFX_DPRAM10')}
    resource['BRAM_total'] = resource['EFX_RAM10']+resource['EFX_DPRAM10']
    timing = read_timing(reports/'mobilenet.timing.rpt')
    staged_period = float(re.search(r'-period\s+([\d.]+)', (stage/'mobilenet.sdc').read_text()).group(1))
    assert abs(staged_period-timing['period_ns']) <= 0.000501
    timing['requested_mhz'] = round(1000/staged_period, 3)
    timing['sdc_period_ns'] = staged_period
    assert resource['BRAM_total'] <= args.bram_budget
    assert timing['setup_slack_ns'] >= 0 and timing['hold_slack_ns'] >= 0
    rom_resets = re.findall(r'defparam \\core/unit/model_parameters.parameters/g_packed.g_compact.g_(?:low|high)\[\d+\].u_rom \.RESET_RAM = ([^;]+);', netlist)
    assert len(rom_resets) == 25 and set(rom_resets) == {'"SYNC"'}
    trials = []
    for directory in args.timing_trial_directory:
        trial_reports = directory/'outflow'
        trial = read_timing(trial_reports/'mobilenet.timing.rpt')
        trial_mapping = (trial_reports/'mobilenet.map.rpt').read_text()
        trial['name'] = directory.as_posix()
        trial['resources'] = {name: int(re.search(rf'{name}\s*:\s*(\d+)', trial_mapping).group(1))
                              for name in resource if name != 'BRAM_total'}
        trial['map_report_sha256'] = sha(trial_reports/'mobilenet.map.rpt')
        trials.append(trial)
    with args.metrics.open() as stream:
        commands = list(csv.DictReader(stream))
    tests = {
        'cache_rtl': passed('build/sim/cache.log', r'PASS cache:[^\r\n]+'),
        'cache_mapped': passed('build/sim/cache_mapped.log', r'PASS cache:[^\r\n]+'),
        'core_rtl': passed(args.unit_log, r'PASS: \d+ cases, \d+ commands, \d+ cycles'),
        'bus_rtl': passed(args.bus_log, r'PASS bus:[^\r\n]+'),
        'model_assets_rtl': passed('build/sim/assets.log', r'PASS assets:[^\r\n]+'),
        'model_bus_rtl': passed('build/sim/model_bus.log', r'PASS epoch11 bus:[^\r\n]+; 6 commands, \d+ cycles'),
        'model_bus_mapped': passed('build/sim/model_postmap.log', r'PASS epoch11 bus:[^\r\n]+; 6 commands, \d+ cycles'),
        'postprocess_rtl': passed('build/sim/postprocess.log', r'PASS (?:serial|grouped|parallel) postprocess:[^\r\n]+'),
    }
    if (ROOT/'build/sim/dsp_quant_probe.log').exists():
        tests['dsp_primitive_probe'] = passed('build/sim/dsp_quant_probe.log', r'PASS W feedback:[^\r\n]+')
    tests['shared_dw_buffer'] = passed('build/sim/dw_buffer.log', r'PASS shared DW buffer:[^\r\n]+')
    tests['shared_dw_buffer']['scope'] = 'Unchanged legacy register-buffer reference; production uses the BRAM buffer below.'
    tests['bram_dw_buffer'] = passed('build/sim/dw_buffer_bram.log', r'PASS BRAM DW buffer:[^\r\n]+')
    tests['pe_input_mux'] = passed('build/sim/input_mux.log', r'PASS PE input mux:[^\r\n]+')
    tests['compact'] = passed('build/sim/compact.log', r'PASS compact:[^\r\n]+')
    tests['model_assets_rtl']['testbench_sha256'] = sha(ROOT/'sim/tb_model_assets.sv')
    tests['model_assets_rtl']['compiled_simulator_sha256'] = sha(ROOT/'build/sim/assets.vvp')
    tests['model_bus_mapped']['compiled_simulator_sha256'] = sha(ROOT/'build/sim/model_postmap.vvp')
    tests['model_bus_mapped']['netlist_sha256'] = sha(reports/'mobilenet.map.v')
    cache_preparation = json.loads((ROOT/'build/sim/cache_netlist.json').read_text())
    assert cache_preparation['coalesced_output_alias_bits'] == 800
    assert cache_preparation['source_sha256'] == sha(Path(cache_preparation['source']))
    assert cache_preparation['prepared_sha256'] == sha(Path(cache_preparation['prepared']))
    assert cache_preparation['cache_rtl_sha256'] == sha(ROOT/'rtl/mn_cache.sv')
    assert cache_preparation['testbench_sha256'] == sha(ROOT/'sim/tb_cache.sv')
    tests['cache_mapped']['netlist_preparation'] = cache_preparation
    tests['cache_mapped']['compiled_simulator_sha256'] = sha(ROOT/'build/sim/cache_mapped.vvp')
    tests['cache_mapped']['reused_from_previous_iteration'] = True
    tests['cache_mapped']['reuse_reason'] = 'Cache RTL and its testbench are unchanged; hashes checked above.'
    tests['instruction_fifo'] = passed('build/sim/fifo.log', r'PASS FIFO:[^\r\n]+')
    tests['instruction_fifo_mapped'] = passed('build/sim/fifo_mapped.log', r'PASS FIFO:[^\r\n]+')
    tests['all_instruction_cycles'] = passed('build/sim/executor_cycles.log', r'PASS cycle model:[^\r\n]+')
    tests['executor_timing'] = passed('build/sim/executor4_timing.log', r'PASS: \d+ cases, 6 commands, \d+ cycles')
    tests['executor_timing']['scope'] = 'Unpadded 3x3 and 7x7 DW; four queued single-channel PW commands'
    trace = (ROOT/'build/sim/executor4_timing.log').read_text()
    pops = [int(x) for x in re.findall(r'TIMING_POP cycle=(\d+)', trace)]
    dones = [int(x) for x in re.findall(r'TIMING_DONE cycle=(\d+)', trace)]
    macs = [[int(x), int(y)] for x,y in re.findall(r'TIMING_MAC cycle=(\d+) tap=(\d+)', trace)]
    assert len(pops) == len(dones) == 6
    execution = [b-a for a,b in zip(pops,dones)]
    assert execution == [77,117,9,9,9,9]
    assert len(macs) == 58
    for i,width,start,length in ((0,3,63,9),(1,7,63,49)):
        group = macs[:9] if i == 0 else macs[9:]
        expected = [r*width+c for r in range(width)
                    for c in (range(width) if r%2 == 0 else range(width-1,-1,-1))]
        assert [x[0] for x in group] == list(range(pops[i]+start,pops[i]+start+length))
        assert [x[1] for x in group] == expected
    assert all(pops[i] == dones[i-1]+1 for i in range(3,6))
    executor_timing = {'dw3_pop': pops[0], 'dw3_mac_cycle_and_tap': macs[:9],
                       'dw3_done': dones[0], 'dw7_pop': pops[1],
                       'dw7_mac_cycle_and_tap': macs[9:], 'dw7_done': dones[1],
                       'pw_queued_pops': pops[2:], 'pw_dones': dones[2:],
                       'execution_cycles': execution, 'queued_switch_cycles': 1}
    cases, count, cycles = [int(x) for x in re.findall(r'\d+', tests['core_rtl']['summary'])]
    assert len(commands) == count and max(int(x['case']) for x in commands) == cases
    tests['core_rtl'].update(cases=cases, commands=count, cycles=cycles,
                             expected_error_commands=sum(int(x['error']) != 0 for x in commands),
                             metrics_sha256=sha(args.metrics))
    run_manifest = ROOT/'build/sim/unit_regression.json'
    if run_manifest.exists():
        tests['core_rtl']['execution'] = json.loads(run_manifest.read_text())
        tests['core_rtl']['execution']['compiled_simulator_sha256'] = sha(ROOT/'build/sim/unit.vvp')
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
              'baseline_git_commit': args.baseline, 'top': 'cyclegan_bus_top',
              'device': 'Ti60F225', 'efinity': '2026.1.132', 'timing_model': 'C4',
              'staged_rtl_matches_current': True, 'retiming': False,
              'synthesis_resources': resource,
              'bram_budget': args.bram_budget,
              'cache_native_planes': {'count': 160, 'parameters': cache_parameters},
              'window_native_banks': {'count': 8, 'parameters': window_parameters},
              'pe_source_selection_lut4': len(input_masks),
              'signed32_compact_lut4': len(compact_masks),
              'internal_timing': timing,
              'timing_experiments': trials,
              'model_rom_native_output_clear': {'banks': len(rom_resets), 'reset_ram': 'SYNC',
                                               'read_latency_cycles': 1},
              'tests': tests, 'full_network_instruction_model': frames,
              'full_network_instruction_model_reused_from_previous_iteration': True,
              'executor_timing': executor_timing,
              'host_protocol': {'row_commits_checked': 70, 'addresses_checked': 7,
                                'scope': 'Python protocol model; separate RTL bus tests'},
              'limitations': ['host keeps full feature maps and interleaves transpose phases',
                              'no board transport, DDR DMA or autonomous FPGA layer scheduler',
                              'no full-frame RTL simulation or on-board inference validation'],
              'rtl_sha256': {p.relative_to(ROOT).as_posix(): sha(p) for p in files},
              'report_sha256': {p.name: sha(p) for p in [reports/'mobilenet.map.rpt',
                                                       reports/'mobilenet.timing.rpt',
                                                       reports/'mobilenet.place.rpt']}}
    target = args.output
    target.write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print('RESULTS_RECORDED', cases, 'cases,', count, 'commands,', resource['BRAM_total'], 'BRAM')


if __name__ == '__main__':
    main()
