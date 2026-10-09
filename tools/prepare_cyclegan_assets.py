"""Re-export epoch11 fixed BN, integer references, and native ROM assets.

Reference sources are reused with attribution; the reference tree is read-only.
Run this with the bundled Python containing NumPy and Pillow.
"""
import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--reference-root', type=Path, default=Path(r'C:\Users\Administrator\Desktop\jisuan\pe10_10'))
args = parser.parse_args()
ref = args.reference_root.resolve()
out = ROOT / 'build' / 'cyclegan_model'
subprocess.run([sys.executable, str(ref / 'tools' / 'prepare_generator_params.py'),
                '--checkpoint', str(ref / 'netG_B_epoch11.pth'), '--output', str(out),
                '--image', str(ref / 'weight' / 'test.jpg')], check=True)
rtl = ROOT / 'rtl'
(rtl / 'mn_model_params_init.vh').write_bytes((out / 'generator_params_packed_init.vh').read_bytes())
(rtl / 'mn_tanh_u8.mem').write_bytes((out / 'tanh_u8.mem').read_bytes())
text = (ref / 'generator' / 'rtl' / 'generator_param_rom.v').read_text(encoding='utf-8')
text = text.replace('`include "generator_config.vh"', '// Epoch11 output kernel is fixed below.')
text = text.replace('generator_param_rom', 'mn_model_rom').replace('`GENERATOR_OUTPUT_KERNEL', '7')
text = text.replace('generator_params_packed_init.vh', 'mn_model_params_init.vh')
text = '// Derived from pe10_10/generator/rtl/generator_param_rom.v.\n' + text
(rtl / 'mn_model_rom.sv').write_text(text, encoding='utf-8')
text = (ref / 'generator' / 'rtl' / 'tanh_bram.v').read_text(encoding='utf-8')
text = text.replace('tanh_bram', 'mn_tanh_bram').replace('module tanh_tile', 'module mn_tanh_tile')
text = text.replace('input wire [35:0] sum[0:99]', 'input wire [3199:0] in_data')
text = text.replace('reg active=0;', 'wire [35:0] sum[0:99];\n genvar lane;\n generate for(lane=0;lane<100;lane=lane+1) begin:g_sum\n assign sum[lane]={{4{in_data[lane*32+31]}},in_data[lane*32+:32]};\n end endgenerate\n reg active=0;')
text = text.replace('"tanh_u8.mem"', '"rtl/mn_tanh_u8.mem"')
text = '// Derived from pe10_10/generator/rtl/tanh_bram.v; same Q4.8-to-uint8 LUT.\n' + text
(rtl / 'mn_tanh.sv').write_text(text, encoding='utf-8')
print('CYCLE_GAN_ASSETS_PASS')
