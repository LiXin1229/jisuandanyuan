"""Run complete, independent vector cases; keep multi-command cases together."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import csv
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
cli = argparse.ArgumentParser(description=__doc__)
cli.add_argument('--jobs', type=int, default=1)
args = cli.parse_args()
if args.jobs < 1:
    cli.error('--jobs must be positive')
source = ROOT/'sim/vectors.txt'
target = ROOT/'build/sim'
text = source.read_text()
markers = list(re.finditer(r'(?m)^8 ([0-9a-f]+) [^\n]+\n', text))
blocks = [(int(m[1], 16), text[m.start():markers[i+1].start() if i+1<len(markers) else len(text)])
          for i,m in enumerate(markers)]
assert markers and markers[0].start() == 0
jobs = min(args.jobs, len(blocks))
manifest = {'jobs': jobs, 'case_count': len(blocks),
            'vectors_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
            'compiled_simulator_sha256': hashlib.sha256((target/'unit.vvp').read_bytes()).hexdigest(),
            'case_scope': 'Each case initializes its own inputs; commands within a case retain queue/accumulator state.',
            'cycles_scope': 'Sum of testbench cycles; parallel runs include one reset per shard.'}
if jobs == 1:
    result = subprocess.run(['vvp', '-i', str(target/'unit.vvp')], cwd=ROOT)
    if result.returncode:
        sys.exit(result.returncode)
else:
    groups = [[] for _ in range(jobs)]
    sizes = [0]*jobs
    # Balance memory traffic while preserving the complete per-case sequence.
    for item in sorted(blocks, key=lambda x: len(x[1]), reverse=True):
        j = min(range(jobs), key=sizes.__getitem__)
        groups[j].append(item)
        sizes[j] += len(item[1])

    def run(j):
        group = sorted(groups[j])
        vectors = target/f'unit_shard_{j}.txt'
        metrics = target/f'unit_shard_{j}.csv'
        log = target/f'unit_shard_{j}.log'
        vectors.write_text(''.join(x[1] for x in group))
        with log.open('w') as stream:
            result = subprocess.run(['vvp', '-i', str(target/'unit.vvp'),
                f'+vectors={vectors.relative_to(ROOT).as_posix()}',
                f'+metrics={metrics.relative_to(ROOT).as_posix()}'], cwd=ROOT,
                stdout=stream, stderr=subprocess.STDOUT)
        output = log.read_text()
        match = re.search(r'PASS: (\d+) cases, (\d+) commands, (\d+) cycles', output)
        if result.returncode or not match:
            raise RuntimeError(f'Shard {j} failed:\n{output}')
        with metrics.open() as stream:
            rows = list(csv.DictReader(stream))
        expected = sum(line.startswith('3 ') for _,block in group for line in block.splitlines())
        assert int(match[2]) == len(rows) == expected
        assert {int(x['case']) for x in rows} == {x[0] for x in group}
        print(f'PASS shard {j}: {len(group)} cases, {len(rows)} commands', flush=True)
        return rows, int(match[3])

    with ThreadPoolExecutor(max_workers=jobs) as pool:
        results = list(pool.map(run, range(jobs)))
    rows = sorted((row for group,_ in results for row in group),
                  key=lambda x: (int(x['case']), int(x['command'])))
    expected = sum(line.startswith('3 ') for line in text.splitlines())
    assert len(rows) == expected
    assert {int(x['case']) for x in rows} == {x[0] for x in blocks}
    for i,row in enumerate(rows, 1):
        row['command'] = i
    with (target/'commands.csv').open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=rows[0].keys())
        writer.writeheader()
        writer.writerows(rows)
    print(f'PASS: {len(blocks)} cases, {len(rows)} commands, {sum(x[1] for x in results)} cycles')
(target/'unit_regression.json').write_text(json.dumps(manifest, indent=2)+'\n')
