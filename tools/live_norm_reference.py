"""Deterministic per-image affine normalization for int8 Q4.4 activations.

Population variance, epsilon = 1/100000.  The square-root radicand has
32 fractional bits; floor sqrt is used, followed by ties-to-even coefficient
rounding and signed-16 saturation. b is computed before rounding a.
This is the hardware contract, not a claim of float32 PyTorch bit identity.
"""
from math import isqrt
import numpy as np

SAMPLE_COUNTS = (76800, 19200, 4800, 1200)
CHANNELS = (8, 8, 16, 16, 32) + (32,) * 18 + (16, 8, 8)
COUNTS = (76800, 19200, 19200, 4800, 4800) + (1200,) * 18 + (4800, 19200, 76800)
BN_KEYS = ['model.2', 'model.5.depthwise.1', 'model.5.pointwise.1',
           'model.7.depthwise.1', 'model.7.pointwise.1']
BN_KEYS += [f'model.{i}.{part}.1' for i in range(9, 18) for part in ('depthwise', 'pointwise')]
BN_KEYS += ['model.19', 'model.22', 'model.25']
BN_BASES = [51, 139, 283, 459, 1003]
BN_BASES += [base + 1440 * r for r in range(9) for base in (1355, 2443)]
BN_BASES += [18635, 19819, 20411]
OFFSETS = np.cumsum((0,) + tuple(2 * c for c in CHANNELS)).tolist()

def round_ratio(num, den):
    negative = num < 0
    q, r = divmod(abs(int(num)), int(den))
    q += 2 * r > den or (2 * r == den and q & 1)
    return -q if negative else q

def coefficient(n, total, squares, gamma, beta):
    d = n * squares - total * total
    if n not in SAMPLE_COUNTS or d < 0:
        raise ValueError('Invalid channel statistics')
    eps = round_ratio(256 * n * n * (1 << 32), 100000)
    root = isqrt((d << 32) + eps)
    a = round_ratio(int(gamma) * n * (1 << 20), root)
    b = round_ratio(int(beta) * root - int(gamma) * total * (1 << 16), root)
    return max(-32768, min(32767, a)), max(-32768, min(32767, b))

def affine(x, gamma, beta):
    x = np.asarray(x, dtype=np.int64)
    n = x.shape[1] * x.shape[2]
    ab = [coefficient(n, int(v.sum()), int((v*v).sum()), g, b)
          for v, g, b in zip(x, gamma, beta)]
    a, b = np.asarray(ab, dtype=np.int64).T
    return np.clip((x * a[:, None, None] + 16*b[:, None, None] + 128) >> 8,
                   -128, 127), a, b
