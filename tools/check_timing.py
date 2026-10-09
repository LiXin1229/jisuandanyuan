"""Require both setup and hold closure in an Efinity post-route report."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def read_timing(path):
    report = path.read_text(encoding='utf-8')
    target = re.search(r'User target constrained clocks.*?\n\s*clk\s+([\d.]+)\s+([\d.]+)', report, re.S)
    analyzed = re.search(r'Maximum possible analyzed clocks frequency.*?\n\s*clk\s+([\d.]+)\s+([\d.]+)', report, re.S)
    setup = re.search(r'Setup \(Max\).*?\n\s*clk\s+clk\s+[\d.]+\s+([\d.-]+)', report, re.S)
    hold = re.search(r'Hold \(Min\).*?\n\s*clk\s+clk\s+[\d.]+\s+([\d.-]+)', report, re.S)
    if not all((target, analyzed, setup, hold)):
        raise ValueError(f'Missing clk timing results: {path}')
    return dict(target_mhz=float(target[2]), period_ns=float(target[1]),
                analyzed_fmax_mhz=float(analyzed[2]), min_period_ns=float(analyzed[1]),
                setup_slack_ns=float(setup[1]), hold_slack_ns=float(hold[1]),
                board_io_constrained=False, report_sha256=hashlib.sha256(path.read_bytes()).hexdigest())


if __name__ == '__main__':
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('report', type=Path)
    cli.add_argument('--output', type=Path)
    args = cli.parse_args()
    result = read_timing(args.report)
    if args.output:
        args.output.write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    if result['setup_slack_ns'] < 0 or result['hold_slack_ns'] < 0:
        raise SystemExit(f'FAIL internal timing: {result}')
    print(f"PASS internal timing: {result['target_mhz']:g} MHz, "
          f"setup {result['setup_slack_ns']:.3f} ns, hold {result['hold_slack_ns']:.3f} ns, "
          f"analyzed Fmax {result['analyzed_fmax_mhz']:.3f} MHz; board I/O unconstrained")
