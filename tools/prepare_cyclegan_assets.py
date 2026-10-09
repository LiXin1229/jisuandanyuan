"""Re-export epoch11 fixed BN, integer references, and native ROM data.

The optimized RTL wrappers are maintained in rtl/ and must not be overwritten
by older reference wrappers. The reference tree is read-only.
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
print('CYCLE_GAN_ASSETS_PASS')
