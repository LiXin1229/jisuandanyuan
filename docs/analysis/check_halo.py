"""Check the proposed fixed-permutation halo traversal, not an RTL simulation."""


def rotate(grid, dy, dx):
    return [[grid[(r + dy) % 16][(c + dx) % 16] for c in range(16)]
            for r in range(16)]


def check(kh, kw, ay, ax):
    original = [[r * 16 + c for c in range(16)] for r in range(16)]
    work = rotate(original, 3 - ay, 3 - ax)
    seen = {(ay, ax)}  # The main tile's tap was computed before traversal.
    for ky in range(kh):
        cols = list(range(kw)) if ky % 2 == 0 else list(range(kw - 1, -1, -1))
        for index, kx in enumerate(cols):
            for r in range(10):
                for c in range(10):
                    assert work[r][c] == original[r + 3 + ky - ay][c + 3 + kx - ax]
            if (ky, kx) != (ay, ax):
                assert (ky, kx) not in seen
                seen.add((ky, kx))
            if index != len(cols) - 1:
                work = rotate(work, 0, 1 if ky % 2 == 0 else -1)
        if ky != kh - 1:
            work = rotate(work, 1, 0)
    assert len(seen) == kh * kw
    print(f"PASS halo {kh}x{kw}: {len(seen)} unique taps, all 100 lanes per tap")


for dims in [(1, 2, 0, 0), (2, 1, 0, 0), (2, 2, 0, 0),
             (3, 3, 1, 1), (7, 7, 3, 3)]:
    check(*dims)

assert 32 * 24 * 3 == 2304
assert 800 * 1024 // 8 == 102400
assert 800 * 1024 // 10240 == 80
assert 16 * 16 * 8 == 2048
assert 25 * 3 == 75
print("PASS arithmetic: frame/cache capacity, 80 BRAM, 2048 halo FF, 75 pool comparators")
print("LIMIT: no RTL, padding-loader, quantization-accuracy or physical-resource verification")
