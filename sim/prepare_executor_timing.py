"""Extract complete independent cases for the executor edge trace."""
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
names = json.loads((ROOT/'sim/cases.json').read_text(encoding='utf-8'))
selected = [names.index(name)+1 for name in (
    'DW 3x3, pos 1,1, shape 30x30, pad 0, act 0',
    'DW 7x7, pos 1,1, shape 30x30, pad 0, act 0',
    'FIFO queued commands preserve execution and write order')]
source = (ROOT/'sim/vectors.txt').read_text()
markers = list(re.finditer(r'(?m)^8 ([0-9a-f]+) [^\n]+\n', source))
blocks = {int(marker[1], 16): source[marker.start():
          markers[i+1].start() if i+1 < len(markers) else len(source)]
          for i, marker in enumerate(markers)}
target = ROOT/'build/sim/executor4_vectors.txt'
target.write_text(''.join(blocks[case] for case in selected))
print('Prepared executor trace cases', selected)
