"""Coalesce identical bitwise output buffers for Icarus, preserving all cells.

Efinity emits 800 separate continuous assignments for the two aliased cache
read outputs. Resolving that wide bus per bit is unusually slow in Icarus.
One vector assignment has the same bit values, strengths and X/Z semantics.
The original synthesis netlist and its resource report are never modified.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

cli = argparse.ArgumentParser(description=__doc__)
cli.add_argument('source', type=Path)
cli.add_argument('output', type=Path)
args = cli.parse_args()
root = Path(__file__).resolve().parents[1]
source = args.source.read_text()
assert len(re.findall(r'(?m)^module mn_cache\b', source)) == 1
assert len(re.findall(r'(?m)^endmodule\b', source)) == 1
pattern = r'(?m)^    assign host_rdata\[(\d+)\] = rd_data\[\1\][^\n]*\n'
indices = re.findall(pattern, source)
assert sorted(map(int, indices)) == list(range(800))
prepared = re.sub(pattern, '', source)
prepared = re.sub(r'(?m)^endmodule\b', '    assign host_rdata = rd_data;\nendmodule', prepared)
args.output.write_text(prepared)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
manifest = {'source': str(args.source.resolve()), 'source_sha256': sha(args.source),
            'prepared': str(args.output.resolve()), 'prepared_sha256': sha(args.output),
            'coalesced_output_alias_bits': len(indices),
            'transformation': '800 single-bit continuous output buffers to one 800-bit buffer; all functional cells unchanged',
            'cache_rtl_sha256': sha(root/'rtl/mn_cache.sv'),
            'testbench_sha256': sha(root/'sim/tb_cache.sv')}
(root/'build/sim/cache_netlist.json').write_text(json.dumps(manifest, indent=2)+'\n')
print('CACHE_NETLIST_PREPARED: 800 equivalent output aliases coalesced; all functional cells unchanged')
