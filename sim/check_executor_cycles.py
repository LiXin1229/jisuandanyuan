"""Check every measured instruction latency against the shared executor schedule."""
import argparse
import csv
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
cli = argparse.ArgumentParser(description=__doc__)
cli.add_argument('--vectors', type=Path, default=ROOT/'sim/vectors.txt')
cli.add_argument('--metrics', type=Path, default=ROOT/'build/sim/commands.csv')
args = cli.parse_args()
commands = [int(line.split()[3], 16) for line in args.vectors.read_text().splitlines()
            if line.startswith('3 ')]
with args.metrics.open() as stream:
    rows = list(csv.DictReader(stream))
assert len(commands) == len(rows)
groups = {}
for command, row in zip(commands, rows):
    def field(offset, width=1):
        return (command >> offset) & ((1 << width)-1)
    op = field(0, 4)
    channels = field(36, 5)+1
    kernel = field(41, 3)
    rounding = field(86) and not field(87)
    raw = field(88)
    if int(row['error']) or op == 3:
        expected = 2
    elif op == 1:
        expected = 10
    elif op == 5:
        expected = 10+rounding
    elif op == 0 or kernel == 5:
        expected = channels+8+rounding-raw
        if field(118) and not raw:
            expected += 54
    else:
        reflect = field(50, 2) == 2
        edges = field(54, 4)
        valid_w, valid_h = field(58, 4)+1, field(62, 4)+1
        sides = sum((bool(edges & 1) and reflect,
                     bool(edges & 2) and (reflect or valid_w != 10),
                     bool(edges & 4) and reflect,
                     bool(edges & 8) and (reflect or valid_h != 10)))
        area = (2, 2, 4, 9, 49)[kernel]
        origin = 0 if kernel == 4 else 2 if kernel == 3 else 3
        expected = area+17+2*origin+3*sides-raw
        if field(118) and not raw:
            expected += 54
    actual = int(row['cycles'])-1
    assert actual == expected, (row, expected, actual)
    key = (op, kernel if op in (2, 4) else None)
    groups.setdefault(key, set()).add(actual)
print(f'PASS cycle model: {len(rows)} commands, execution/rounding/padding/raw/Tanh latencies')
for key, values in sorted(groups.items()):
    print('operation/kernel', key, 'E', sorted(values))
