"""Read-only CycleGAN architecture checks; does not run training or alter RTL.

Uses the reference project's restricted checkpoint reader (no torch/pickle code
execution). The JSON output contains analytical estimates, not synthesis results.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import random
import sys
from pathlib import Path


def packed_pixel(r, c):
    return ((r // 5) * 2 + c // 5) * 25 + (r % 5) * 5 + c % 5


def check_row_writes():
    """Prove 20-bit masks update exactly one spatial row in quadrant format."""
    pixels = [((i * 73) + 19) & 255 for i in range(100)]
    tile = sum(pixels[r * 10 + c] << (8 * packed_pixel(r, c))
               for r in range(10) for c in range(10))
    checks = 0
    for row in range(10):
        q0 = (row // 5) * 2
        mask = sum(1 << (q * 10 + (row % 5) * 2 + s)
                   for q in (q0, q0 + 1) for s in (0, 1))
        assert mask.bit_count() == 4
        new = [(17 * c + 101 + row) & 255 for c in range(10)]
        data = sum(new[c] << (8 * packed_pixel(row, c)) for c in range(10))
        written = tile
        for bank in range(40):
            if mask >> bank & 1:
                bits = ((1 << 20) - 1) << (20 * bank)
                written = (written & ~bits) | (data & bits)
        for r in range(10):
            for c in range(10):
                actual = (written >> (8 * packed_pixel(r, c))) & 255
                assert actual == (new[c] if r == row else pixels[r * 10 + c])
                checks += 1
    return {"pixel_comparisons": checks, "write_slices_per_channel_row": 4,
            "row_bits": 80, "rgb_row_buffer_bits": 240}


def check_transpose():
    """Independent scatter vs four small cross-correlations, before quantizing."""
    rng = random.Random(20261009)
    count = 0
    for h, w, cin, cout in [(1, 1, 1, 1), (3, 4, 3, 2), (6, 8, 8, 3)]:
        x = [[[rng.randrange(-128, 128) for _ in range(w)] for _ in range(h)]
             for _ in range(cin)]
        k = [[[[rng.randrange(-1024, 1024) for _ in range(3)] for _ in range(3)]
              for _ in range(cout)] for _ in range(cin)]
        scatter = [[[0] * (2 * w) for _ in range(2 * h)] for _ in range(cout)]
        for ic in range(cin):
            for oc in range(cout):
                for y in range(h):
                    for z in range(w):
                        for kr in range(3):
                            for kc in range(3):
                                oy, ox = 2 * y + kr - 1, 2 * z + kc - 1
                                if 0 <= oy < 2 * h and 0 <= ox < 2 * w:
                                    scatter[oc][oy][ox] += x[ic][y][z] * k[ic][oc][kr][kc]
        for oc in range(cout):
            for y in range(h):
                for z in range(w):
                    for py in range(2):
                        for px in range(2):
                            total = 0
                            for ic in range(cin):
                                for dy in range(py + 1):
                                    for dx in range(px + 1):
                                        if y + dy < h and z + dx < w:
                                            kr = 2 * (1 - dy) if py else 1
                                            kc = 2 * (1 - dx) if px else 1
                                            total += x[ic][y + dy][z + dx] * k[ic][oc][kr][kc]
                            assert total == scatter[oc][2 * y + py][2 * z + px]
                            count += 1
    return {"accumulator_comparisons": count, "phase_shapes": ["1x1", "1x2", "2x1", "2x2"]}


def read_checkpoint(root, checkpoint):
    spec = importlib.util.spec_from_file_location("cyclegan_safe_checkpoint",
                                                 root / "tools" / "inspect_pth.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    archive, prefix, state = mod.load_state_dict(checkpoint)
    quant = lambda v: max(-32768, min(32767, round(v * 256)))
    shapes, conv_words, norm_words, bounds, norm_clips = {}, 0, 0, [], []
    def values(key):
        return mod.contiguous_values(archive, prefix, state[key])
    with archive:
        for key, tensor in state.items():
            if not isinstance(tensor, mod.TensorRef):
                continue
            shapes[key] = list(tensor.shape)
            if key.endswith("weight") and len(tensor.shape) == 4:
                data = [quant(v) for v in values(key)]
                conv_words += len(data)
                ci, co, kh, kw = tensor.shape
                if key in ("model.18.weight", "model.21.weight", "model.24.weight"):
                    bound = max(128 * sum(abs(data[((i * co + o) * kh + kr) * kw + kc])
                                         for i in range(ci)
                                         for kr in ([1] if not py else [0, 2])
                                         for kc in ([1] if not px else [0, 2]))
                                for o in range(co) for py in range(2) for px in range(2))
                else:
                    stride = co * kh * kw
                    bound = max(128 * sum(abs(v) for v in data[o * stride:(o + 1) * stride])
                                for o in range(ci))
                bounds.append({"key": key, "absolute_accumulator_bound": bound})
            if key.endswith("running_mean"):
                base = key.removesuffix(".running_mean")
                gamma, beta, mean, var = [[quant(v) / 256 for v in values(base + suffix)]
                                          for suffix in (".weight", ".bias", ".running_mean", ".running_var")]
                pairs = []
                for i, (g, b, m, v) in enumerate(zip(gamma, beta, mean, var)):
                    assert v >= 0
                    alpha = g / math.sqrt(v + 1e-5)
                    shift = b - m * alpha
                    for name, number in (("a", alpha), ("b", shift)):
                        if not -32768 <= round(number * 256) <= 32767:
                            norm_clips.append({"layer": base, "channel": i, "coefficient": name})
                    pairs.append((quant(alpha), quant(shift)))
                norm_words += 2 * len(pairs)
                bounds.append({"key": base, "absolute_accumulator_bound":
                               max(128 * abs(a) + 16 * abs(b) for a, b in pairs)})
    assert shapes["model.1.depthwise.weight"] == [3, 1, 3, 3]
    assert shapes["model.1.pointwise.weight"] == [8, 3, 1, 1]
    for idx, cin, cout in ((5, 8, 16), (7, 16, 32)):
        assert shapes[f"model.{idx}.depthwise.0.weight"] == [cin, 1, 3, 3]
        assert shapes[f"model.{idx}.pointwise.0.weight"] == [cout, cin, 1, 1]
    for idx in range(9, 18):
        assert shapes[f"model.{idx}.depthwise.0.weight"] == [32, 1, 3, 3]
        assert shapes[f"model.{idx}.pointwise.0.weight"] == [32, 32, 1, 1]
    for idx, cin, cout in ((18, 32, 16), (21, 16, 8), (24, 8, 8)):
        assert shapes[f"model.{idx}.weight"] == [cin, cout, 3, 3]
    final_shape = shapes["model.28.weight"]
    assert final_shape[:2] == [3, 8] and final_shape[2] == final_shape[3] and final_shape[2] in (3, 7)
    assert sum(key.endswith("running_mean") for key in shapes) == 26
    return {"path": str(checkpoint), "sha256": hashlib.sha256(checkpoint.read_bytes()).hexdigest(),
            "final_weight_shape": final_shape, "conv_weight_words": conv_words,
            "fixed_affine_words": norm_words, "total_deployment_words": conv_words + norm_words,
            "bn_layers": 26, "bn_clipped_coefficients": norm_clips,
            "maximum_operator_bound": max(b["absolute_accumulator_bound"] for b in bounds),
            "final_operator_bound": next(b["absolute_accumulator_bound"] for b in bounds if b["key"] == "model.28.weight"),
            "bounds": bounds, "shapes": shapes}


def capacities():
    # Simple dual port native 512x20 slices; these are physical BRAM counts.
    schemes = {
        "three_caches_existing_dw_streamed_parameters": dict(cache=120, halo=10, windows=40, parameters=8, phase=8, tanh=4),
        "three_caches_shared_windows_streamed_parameters": dict(cache=120, halo=10, windows=0, parameters=8, phase=8, tanh=4),
        "three_caches_shared_windows_compact_rom": dict(cache=120, halo=10, windows=0, parameters=25, phase=8, tanh=4),
        "three_caches_shared_windows_dense_packed_rom": dict(cache=120, halo=10, windows=0, parameters=36, phase=8, tanh=4),
        "three_caches_all_dw_scratch_in_cache_compact_rom": dict(cache=120, halo=0, windows=0, parameters=25, phase=8, tanh=4),
        "two_caches_shared_windows_streamed_parameters": dict(cache=80, halo=10, windows=0, parameters=8, phase=8, tanh=4),
    }
    for item in schemes.values():
        item["total"] = sum(item.values())
        item["remaining_to_180"] = 180 - item["total"]
    resident = {"rgb_three_tile_rows": 3 * 32 * 3,
                "encoder1_three_tile_rows": 3 * 16 * 8,
                "encoder2_three_tile_rows": 3 * 8 * 16,
                "residual_full_tensor": 4 * 3 * 32,
                "decoder1_three_tile_rows": 3 * 8 * 16,
                "decoder2_three_tile_rows": 3 * 16 * 8,
                "decoder3_three_tile_rows": 3 * 32 * 8}
    assert resident["decoder3_three_tile_rows"] == 768  # Cannot fit one 512-word cache.
    assert 3 * resident["residual_full_tensor"] + 49 + 32 + 4 <= 1536
    return {"bram_estimates": schemes, "resident_tiles": resident,
            "shared_scratch_tiles": dict(windows=49, pw=32, phases=4),
            "residual_three_tensor_plus_scratch_tiles": 3 * 384 + 49 + 32 + 4,
            "encoder_three_rings_plus_scratch_tiles": 288 + 384 + 384 + 49 + 32 + 4,
            "decoder_two_rings_residual_plus_scratch_tiles": 384 + 384 + 384 + 49 + 32 + 4}


def check_paired_row_ring(slots):
    """Abstract decoder publishes row pairs; output convolution needs +/-1 row.

    A slot cannot be overwritten until every consuming output row has finished.
    This is a necessary row-lifetime check, not a full tile/DDR scheduler proof.
    """
    height, produced, consumed = 24, 0, 0
    tags = [None] * slots
    while consumed < height:
        need = range(max(0, consumed - 1), min(height, consumed + 2))
        if all(tags[row % slots] == row for row in need):
            consumed += 1
            continue
        if produced < height:
            pair = [produced, produced + 1]
            oldest_needed = max(0, consumed - 1)
            safe = all(tags[row % slots] is None or tags[row % slots] < oldest_needed
                       for row in pair)
            if safe:
                for row in pair:
                    tags[row % slots] = row
                produced += 2
                continue
        return {"completed": False, "produced_rows": produced,
                "consumed_rows": consumed, "tags": tags}
    return {"completed": True, "produced_rows": produced, "consumed_rows": consumed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-root", type=Path,
                        default=Path(r"C:\Users\Administrator\Desktop\jisuan\pe10_10"))
    parser.add_argument("--checkpoint", type=Path)
    parser.add_argument("--output", type=Path, default=Path("docs/analysis/cyclegan_feasibility.json"))
    args = parser.parse_args()
    root = args.reference_root.resolve()
    checkpoint = (args.checkpoint or root / "netG_B_epoch11.pth").resolve()
    result = {"status": "analytical_checks_only_not_rtl_or_synthesis", "date": "2026-10-09",
              "checkpoint": read_checkpoint(root, checkpoint), "capacity": capacities(),
              "row_write_check": check_row_writes(), "transpose_check": check_transpose(),
              "decoder_pair_row_lifetime": {"three_slots": check_paired_row_ring(3),
                                             "four_slots": check_paired_row_ring(4)},
              "ring_address_example": {"rows": [1, 2, 3], "slots": [1, 2, 0],
                                        "linear_row_pitch_is_sufficient": False},
              "quantization_counterexample": {"input_raw": 1, "weight_raw": 128, "channels": 8,
                                                "quantize_after_sum": (8 * 128 + 128) >> 8,
                                                "quantize_each_channel_then_sum": 8 * ((128 + 128) >> 8)}}
    assert not result["decoder_pair_row_lifetime"]["three_slots"]["completed"]
    assert result["decoder_pair_row_lifetime"]["four_slots"]["completed"]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("FEASIBILITY_CHECK_PASS", json.dumps({
        "parameters": result["checkpoint"]["total_deployment_words"],
        "final_kernel": result["checkpoint"]["final_weight_shape"][2],
        "max_accumulator_bound": result["checkpoint"]["maximum_operator_bound"],
        "row_comparisons": result["row_write_check"]["pixel_comparisons"],
        "transpose_comparisons": result["transpose_check"]["accumulator_comparisons"],
        "output": str(args.output.resolve())}, ensure_ascii=False))


if __name__ == "__main__":
    main()
