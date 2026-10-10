"""Check the all-layer instance-normalization reference and scheduling budget.

Generate build/instance_norm_analysis with the reference exporter first; see
docs/cyclegan_instance_norm_plan.md. This does not modify production RTL.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference-root', type=Path,
                        default=Path(r'C:\Users\Administrator\Desktop\jisuan\pe10_10'))
    parser.add_argument('--model', type=Path, default=ROOT / 'build/instance_norm_analysis')
    args = parser.parse_args()
    ref, model = args.reference_root / 'tools', args.model
    spec = importlib.util.spec_from_file_location('instance_norm_reference', ref / 'live_norm_reference.py')
    reference = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(reference)
    layout = json.loads((model / 'normalization_format.json').read_text())['layers']
    manifest = json.loads((model / 'params_manifest.json').read_text())
    deployed = json.loads((ROOT / 'build/cyclegan_model/params_manifest.json').read_text())
    assert manifest['checkpoint_sha256'] == deployed['checkpoint_sha256']
    assert manifest['live_normalization_layers'] == len(layout) == 26
    gamma_beta = [int(s, 16) for s in (model / 'generator_norm_gamma.mem').read_text().split()]
    gamma_beta = [x - 65536 if x >= 32768 else x for x in gamma_beta]
    assert len(gamma_beta) == 1376
    variants = []
    for variant in ('vectors', 'vectors_inverted'):
        records = json.loads((model / variant / 'live_normalization.json').read_text())
        assert records['layers'] == 26 and len(records['coefficients']) == 26
        offset = checked = amax = bmax = 0
        for layer, record in zip(layout, records['coefficients']):
            n, channels = layer['count'], layer['channels']
            assert record['shape'][0] == channels and np.prod(record['shape'][1:]) == n
            for ch in range(channels):
                gamma, beta = gamma_beta[offset + 2 * ch:offset + 2 * ch + 2]
                assert gamma > 0
                a, b = reference.coefficient(n, record['sums'][ch], record['squares'][ch], gamma, beta)
                assert (a, b) == (record['a'][ch], record['b'][ch])
                # Monotonicity over the complete signed8 domain proves that
                # max-pooling commutes with this quantized affine transform.
                f = np.clip((np.arange(-128, 128, dtype=np.int64) * a + 16 * b + 128) >> 8, -128, 127)
                assert (np.diff(f) >= 0).all()
                checked += 1
                amax, bmax = max(amax, abs(a)), max(bmax, abs(b))
            offset += 2 * channels
        raw = np.load(model / variant / 'bn0_raw_q44.npy').astype(np.int64)
        a = np.array(records['coefficients'][0]['a'])[:, None, None]
        b = np.array(records['coefficients'][0]['b'])[:, None, None]
        norm = lambda x: np.maximum(np.clip((x * a + 16 * b + 128) >> 8, -128, 127), 0)
        pool = lambda x: x.reshape(8, 120, 2, 160, 2).max(axis=(2, 4))
        full, compact = pool(norm(raw)), norm(pool(raw))
        assert np.array_equal(full, compact)
        variants.append(dict(variant=variant, channels_checked=checked,
                             coefficient_abs_max_a=amax, coefficient_abs_max_b=bmax,
                             pool_commutation_checked_values=int(full.size),
                             output_rgb_sha256=sha(model / variant / 'output_u8_tiles.bin')))
    mhz = json.loads((ROOT / 'docs/analysis/cyclegan_cycle_analysis.json').read_text())['compute_mhz']
    samples = sum(x['channels'] * x['count'] for x in layout)
    assert samples == 2841600
    saved = (6144 + 3072 + 1536) - (1536 + 768 + 384)
    result = dict(
        contract='Reference integer per-image Q4.4 normalization; population variance; epsilon=1e-5; not float32 bit identity.',
        reference_sources={n: sha(ref / n) for n in ('live_norm_reference.py', 'export_live_norm.py', 'prepare_generator_params.py')},
        checkpoint_sha256=manifest['checkpoint_sha256'], layers=26,
        channels=sum(x['channels'] for x in layout), samples=samples, tiles=samples // 100,
        positive_gamma_channels=sum(x > 0 for x in gamma_beta[::2]),
        negative_gamma_channels=sum(x < 0 for x in gamma_beta[::2]), compute_mhz=mhz,
        statistic_scan_work=[dict(lanes=p, sample_clocks_per_tile=(100 + p - 1) // p,
                                 total_tile_sampling_cycles=(samples // 100) * ((100 + p - 1) // p),
                                 work_ms=(samples // 100) * ((100 + p - 1) // p) / (mhz * 1000))
                             for p in (1, 4, 8, 12, 16)],
        coefficient_example_budget=dict(clocks_per_channel=300, channels=688,
                                        total_cycles=300 * 688, work_ms=300 * 688 / (mhz * 1000),
                                        note='Planning budget only; not a measured RTL latency; work can overlap later channels.'),
        cache=dict(usable_tile_addresses=1487, pixels_per_tile=100, usable_bytes=148700,
                   resident_residual_three_tensor_bytes=115200,
                   resident_first_transpose_input_plus_output_bytes=115200),
        encoder_pool=dict(unpooled_pw_norm_bytes=[614400, 307200, 153600],
                          raw_pool_storage_bytes=[153600, 76800, 38400],
                          statistics_must_use_unpooled_values=True,
                          old_pw_norm_commands=10752, pooled_pw_norm_commands=2688,
                          saved_norm_commands=saved, saved_executor_and_switch_cycles=saved * 11,
                          saved_executor_ms=saved * 11 / (mhz * 1000),
                          new_total_norm_commands=28416 - saved),
        largest_raw_ddr_tensor=dict(payload_bytes=614400, padded_tile_bytes=786432),
        full_integer_references=variants,
        validation='Two full software references generated with all 26 live normalization layers; all 1376 channel coefficient pairs checked; first-encoder pool commutation checked on 307200 values. No FPGA implementation or new board validation.')
    output = ROOT / 'docs/analysis/cyclegan_instance_norm_feasibility.json'
    output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    print('PASS instance normalization analysis: 26 layers, 688 channels, two full integer references')
    print('PASS positive gamma, all signed8 affine domains, and 307200 pooled values')
    print('Saved encoder NORM commands:', saved, '; execution ms:', result['encoder_pool']['saved_executor_ms'])
    print('Saved', output)


if __name__ == '__main__':
    main()
