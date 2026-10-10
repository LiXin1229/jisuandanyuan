"""Account for the deployed 320x240 schedule, without modifying board RTL.

E is FIFO-pop to done, matching sim/check_executor_cycles.py. One IDLE
clock per instruction is accounted separately. This is an execution lower
bound: DDR, cache-port contention, packing, ownership and stage drains can
add elapsed clocks even with no instruction-source starvation.
"""
import argparse
from collections import defaultdict
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def latency(op, cin=1, kernel=None, rounding=False, keep=False, raw=False,
            sides=0, tanh=False):
    rounding = bool(rounding and not keep)
    if op == 'NORM':
        return 10, 2
    if op == 'ADD':
        return 10 + rounding, 2 + rounding
    if op == 'PW' or kernel == '1x1':
        e = cin + 8 + rounding - raw
        pe = cin + rounding
    else:
        area = {'1x2': 2, '2x1': 2, '2x2': 4, '3x3': 9, '7x7': 49}[kernel]
        load = {'1x2': 22, '2x1': 22, '2x2': 28}.get(kernel, 43)
        e = area + load + 9 * sides - raw
        # The first rounding constant overlaps spatial window loading.
        pe = area + rounding
    return e + (54 if tanh and not raw else 0), pe


def account():
    stages, operations = defaultdict(dict), defaultdict(dict)

    def add(stage, op, **fields):
        e, pe = latency(op, **fields)
        kind = op + ('_' + fields['kernel'] if op in ('DW', 'CONV') else '')
        for row in (stages[stage], operations[kind]):
            for key, value in [('commands', 1), ('busy_cycles', e),
                               ('pe_valid_cycles', pe)]:
                row[key] = row.get(key, 0) + value

    # Encoder emits DW,(DW NORM),PW,NORM/pool for each input tile.
    for layer, (width, height, cin, cout) in enumerate([
            (32, 24, 3, 8), (16, 12, 8, 16), (8, 6, 16, 32)]):
        stage = f'encoder_{layer + 1}'
        for y in range(height):
            for x in range(width):
                sides = (int(x == 0) + int(x == width - 1)
                         + int(y == 0) + int(y == height - 1)) if layer == 0 else 0
                for _ in range(cin):
                    add(stage, 'DW', kernel='3x3', rounding=True, sides=sides)
                    if layer != 0:
                        add(stage, 'NORM')
                for _ in range(cout):
                    add(stage, 'PW', cin=cin, rounding=True)
                    add(stage, 'NORM')

    # Resident nine-block residual path. ADD explicitly disables rounding.
    for _ in range(9 * 4 * 3 * 32):
        add('residual_9', 'DW', kernel='3x3', rounding=True)
        add('residual_9', 'NORM')
        add('residual_9', 'PW', cin=32, rounding=True)
        add('residual_9', 'NORM')
        add('residual_9', 'ADD')

    for layer, (width, height, cin, cout) in enumerate([
            (4, 3, 32, 16), (8, 6, 16, 8), (16, 12, 8, 8)]):
        for _ in range(width * height * cout):
            for kernel in ('1x1', '1x2', '2x1', '2x2'):
                for ch in range(cin):
                    add(f'transpose_{layer + 1}', 'CONV', kernel=kernel,
                        rounding=True, keep=ch != 0, raw=ch != cin - 1)
                add(f'transpose_{layer + 1}', 'NORM')

    for y in range(24):
        for x in range(32):
            sides = int(x == 0) + int(x == 31) + int(y == 0) + int(y == 23)
            for _ in range(3):
                for ch in range(8):
                    add('output_7x7', 'CONV', kernel='7x7', keep=ch != 0,
                        raw=ch != 7, sides=sides, tanh=True)
    return dict(stages), dict(operations)


def total(rows):
    rows = tuple(rows)
    return {key: sum(row[key] for row in rows)
            for key in ('commands', 'busy_cycles', 'pe_valid_cycles')}


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--evidence', type=Path, default=ROOT / 'docs/analysis/cyclegan_video_schedule_optimization.json')
    cli.add_argument('--output', type=Path, default=ROOT / 'docs/analysis/cyclegan_cycle_analysis.json')
    args = cli.parse_args()
    evidence = json.loads(args.evidence.read_text(encoding='utf-8'))
    source_hashes = {}
    for name in ('mobilenet_unit.sv', 'mn_instruction_fifo.sv', 'mn_pe_array.sv',
                 'mn_tanh.sv', 'cyclegan_encoder.sv', 'cyclegan_residual_scheduler.sv',
                 'cyclegan_decoder_scheduler.sv'):
        sha = hashlib.sha256((ROOT / 'rtl' / name).read_bytes()).hexdigest()
        assert sha == evidence['sources']['rtl_sha256'][name], f'RTL changed: {name}'
        source_hashes[name] = sha
    stages, operations = account()
    frame = total(stages.values())
    assert frame['commands'] == 170880
    assert frame['busy_cycles'] == 4974864
    assert frame == total(operations.values())
    groups = {
        'encoder': total(stages[f'encoder_{i}'] for i in (1, 2, 3)),
        'residual': stages['residual_9'].copy(),
        'transpose': total(stages[f'transpose_{i}'] for i in (1, 2, 3)),
        'output': stages['output_7x7'].copy(),
    }
    assert frame == total(groups.values())
    mhz = evidence['sources']['video_contract']['compute_mhz']
    for row in [*stages.values(), *operations.values(), *groups.values(), frame]:
        row['switch_cycles'] = row['commands']
        row['ideal_cycles'] = row['busy_cycles'] + row['switch_cycles']
        row['busy_ms'] = row['busy_cycles'] / (mhz * 1000)
        row['ideal_ms'] = row['ideal_cycles'] / (mhz * 1000)
    frame['ideal_fps_ceiling'] = 1000 / frame['ideal_ms']
    frame['pe_valid_ms_equivalent'] = frame['pe_valid_cycles'] / (mhz * 1000)
    # An exact independent check: each resident block has only three clocks
    # of scheduler fill/drain beyond the instruction execution lower bound.
    residual_elapsed = groups['residual']['ideal_cycles'] + 9 * 3
    physical = []
    for stream in evidence['live_streams']:
        sample = stream['processing_sample']
        assert sample['prefix_mac_cycles'] == frame['busy_cycles']
        assert sample['residual_cycles'] == residual_elapsed == 442395
        assert sample['command_wait_cycles'] == 0
        physical.append({
            'display_mode': 'style' if sample['active_style'] else 'original',
            'evidence_timestamp_utc': stream['timestamp_utc'],
            'sample_elapsed_cycles': sample['cycles'],
            'sample_elapsed_ms': sample['cycles'] / (mhz * 1000),
            'sample_busy_cycles': sample['prefix_mac_cycles'],
            'sample_command_wait_cycles': sample['command_wait_cycles'],
            'sample_data_wait_cycles': sample['data_wait_cycles'],
            'sample_extra_cycles_above_lower_bound': sample['cycles'] - frame['ideal_cycles'],
            'sample_extra_ms_above_lower_bound': (sample['cycles'] - frame['ideal_cycles']) / (mhz * 1000),
            'sample_core_busy_percent': 100 * frame['busy_cycles'] / sample['cycles'],
            'sample_derived_pe_valid_percent': 100 * frame['pe_valid_cycles'] / sample['cycles'],
            'measured_processed_fps': stream['rates']['processed_fps'],
            'measured_frame_period_ms': 1000 / stream['rates']['processed_fps'],
        })
    result = {
        'basis': 'Deployed RTL, measured unit instruction latencies and previously verified board counters; no new board test.',
        'compute_mhz': mhz,
        'tile_pixels': 100,
        'evidence_path': args.evidence.resolve().as_posix(),
        'evidence_sha256': hashlib.sha256(args.evidence.read_bytes()).hexdigest(),
        'bitstream_sha256': evidence['bitstream_sha256'],
        'rtl_sha256': source_hashes,
        'assumptions': [
            'All production instructions process full 10x10 tiles.',
            'Reflect padding costs nine extra clocks per repaired side.',
            'One IDLE clock per command is included as an amortized frame cost.',
            'Ideal excludes DMA, packing port contention, slot ownership, scheduler drains and video synchronization.',
            'PE-valid clocks include rounding constants, normalization and residual addition; they are derived, not measured counters.',
            'Data-wait counters can overlap execution of queued instructions and are not additive idle clocks.',
        ],
        'stages': stages, 'four_phases': groups, 'operations': operations,
        'frame': frame, 'physical_evidence': physical,
        'checks': {'instruction_count': True, 'busy_cycles_match_board': True,
                   'resident_residual_elapsed_cycles_match_board': True,
                   'rtl_hashes_match_verified_deployment': True},
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    print('PASS frame accounting:', frame)
    for name, row in groups.items():
        print(name, row)
    for row in physical:
        print('physical', row)
    print('Saved', args.output)


if __name__ == '__main__':
    main()
