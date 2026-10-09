"""Deterministic integer golden vectors; no dependency beyond Conda Python."""
from pathlib import Path
import json
import random

ROOT = Path(__file__).resolve().parent
rng = random.Random(20261009)
lines, cases = [], []


def emit(op, address=0, auxiliary=0, data=0):
    lines.append(f"{op} {address:x} {auxiliary:x} {data:0200x}")


def pack(tile):
    word = 0
    for r in range(10):
        for c in range(10):
            index = ((r // 5) * 2 + c // 5) * 25 + (r % 5) * 5 + c % 5
            word |= (tile[r][c] & 255) << (index * 8)
    return word


def instruction(op=0, src=100, dst=900, param=0, channels=1, kernel=3,
                act=0, pool=0, write=0, pad=0, width=0, edges=0,
                vw=10, vh=10, tile_pitch=2, row_pitch=12,
                rounding=0, keep=0, more=0, stride2=0):
    fields = [(op, 0), (src, 4), (dst, 14), (param, 24), (channels-1, 36),
              (kernel, 41), (act, 44), (pool, 46), (write, 47), (pad, 50),
              (width, 52), (edges, 54), (vw-1, 58), (vh-1, 62),
              (tile_pitch, 66), (row_pitch, 76), (rounding, 86),
              (keep, 87), (more, 88), (stride2, 89)]
    return sum(value << shift for value, shift in fields)


def begin(name):
    cases.append(name)
    emit(8, len(cases))


def load(address, tile):
    emit(1, address, 15, pack(tile))


def weight(address, value):
    emit(2, address, value & 65535)


def quant(s, act):
    v = s // 256
    if act:
        v = max(0, v)
    if act == 2:
        v = min(96, v)
    return max(-128, min(127, v))


def finish_expected(cmd, accum, act=0, pool=0, write=0, vw=10, vh=10,
                    stride2=0, before=None, already_submitted=False):
    before = before or [[-37] * 10 for _ in range(10)]
    if not already_submitted:
        emit(3, data=cmd)
    emit(4)
    tile = [[quant(accum[r][c], act) if r < vh and c < vw else 0
             for c in range(10)] for r in range(10)]
    if pool or stride2:
        small = []
        for r in range(5):
            row = []
            for c in range(5):
                if pool:
                    row.append(max(tile[y][x] for y in (r*2, r*2+1)
                                   for x in (c*2, c*2+1))
                               if r*2+1 < vh and c*2+1 < vw else 0)
                else:
                    row.append(tile[r*2][c*2])
            small.append(row)
        out = [row[:] for row in before]
        qr, qc = divmod(write-1, 2)
        for r in range(5):
            for c in range(5):
                out[qr*5+r][qc*5+c] = small[r][c]
    elif write:
        out = [row[:] for row in before]
        qr, qc = divmod(write-1, 2)
        for r in range(qr*5, qr*5+5):
            for c in range(qc*5, qc*5+5):
                out[r][c] = tile[r][c]
    else:
        out = tile
    emit(5, 900, data=pack(out))
    return out


for n in (1, 2, 7, 32):
    for act in range(3):
        for rounding in range(2):
            begin(f"PW {n} channels, activation {act}, rounding {rounding}")
            tiles = [[[rng.randrange(-128, 128) for _ in range(10)] for _ in range(10)]
                     for _ in range(n)]
            weights = [rng.randrange(-512, 513) for _ in range(n)]
            # Cross parameter bank boundaries as well as read consecutive cache addresses.
            base = 505
            for i, (tile, w) in enumerate(zip(tiles, weights)):
                load(100+i, tile)
                weight(base+i, w)
            load(900, [[-37]*10 for _ in range(10)])
            sums = [[sum(tiles[i][r][c]*weights[i] for i in range(n)) + 128*rounding
                     for c in range(10)] for r in range(10)]
            finish_expected(instruction(channels=n, param=base, act=act, rounding=rounding),
                            sums, act=act)

for a,b in [(384,128),(-384,-128),(32767,32767),(-32768,-32768),(0,24576)]:
    for rounding in range(2):
        begin(f"NORM a={a}, b={b}, rounding {rounding}")
        tile = [[rng.randrange(-128,128) for _ in range(10)] for _ in range(10)]
        load(100,tile);weight(0,a);weight(1,b)
        load(900,[[-37]*10 for _ in range(10)])
        sums=[[tile[r][c]*a+b*16+rounding*128 for c in range(10)] for r in range(10)]
        finish_expected(instruction(op=1,rounding=rounding),sums)

for mode in ("pool", "partial", "stride2"):
    for write in range(1,5):
        begin(f"{mode} quadrant {write}")
        tile=[[rng.randrange(-100,100) for _ in range(10)] for _ in range(10)]
        load(100,tile);weight(0,256);load(900,[[-37]*10 for _ in range(10)])
        vw,vh=7,9
        pool=mode=="pool";stride2=mode=="stride2"
        finish_expected(instruction(pool=pool,stride2=stride2,write=write,vw=vw,vh=vh),
                        [[v*256 for v in row] for row in tile],pool=pool,stride2=stride2,
                        write=write,vw=vw,vh=vh)

kernels=[(1,2,0,0),(2,1,0,0),(2,2,0,0),(3,3,1,1),(7,7,3,3)]


def reflected(v,n):
    if n==1:
        return 0
    while v<0 or v>=n:
        if v<0:
            v=-v
        if v>=n:
            v=2*n-2-v
    return v


def image_pixel(y,x):
    return ((y*37+x*17+y*x*3+91) % 121)-60


def dw_case(kernel, tx, ty, width, height, pad, act=0, pool=0, write=0, rounding=0):
    kh,kw,ay,ax=kernels[kernel]
    vw=min(10,width-tx*10);vh=min(10,height-ty*10)
    edges=(tx==0) | ((tx*10+vw==width)<<1) | ((ty==0)<<2) | ((ty*10+vh==height)<<3)
    begin(f"DW {kh}x{kw}, pos {tx},{ty}, shape {width}x{height}, pad {pad}, act {act}")
    for dy in (-1,0,1):
        for dx in (-1,0,1):
            if not (0 <= (tx+dx)*10 < width and 0 <= (ty+dy)*10 < height):
                continue
            tile=[[image_pixel((ty+dy)*10+r,(tx+dx)*10+c)
                   if (ty+dy)*10+r < height and (tx+dx)*10+c < width else 111
                   for c in range(10)] for r in range(10)]
            load(100+dy*12+dx*2,tile)
    weights=[rng.randrange(-90,91) for _ in range(kh*kw)]
    for i,w in enumerate(weights):weight(1000+i,w)
    sums=[[0]*10 for _ in range(10)]
    for r in range(vh):
        for c in range(vw):
            total=rounding*128
            for ky in range(kh):
                for kx in range(kw):
                    y=ty*10+r+ky-ay;x=tx*10+c+kx-ax
                    if not (0<=x<width and 0<=y<height):
                        if pad==2:y=reflected(y,height);x=reflected(x,width)
                        else:continue
                    total+=image_pixel(y,x)*weights[ky*kw+kx]
            sums[r][c]=total
    load(900,[[-37]*10 for _ in range(10)])
    finish_expected(instruction(op=2,param=1000,kernel=kernel,act=act,pool=pool,
                                write=write,pad=pad,width=3 if kernel==4 else 1,
                                edges=edges,vw=vw,vh=vh,rounding=rounding),
                    sums,act=act,pool=pool,write=write,vw=vw,vh=vh)

for kernel in range(5):
    dw_case(kernel,1,1,30,30,0)
    dw_case(kernel,0,0,20,20,1,rounding=1)
    dw_case(kernel,1,1,20,20,2)
    dw_case(kernel,1,1,15,17,2,act=1)
    dw_case(kernel,0,0,1,1,2)
dw_case(3,0,1,20,30,2,pool=1,write=4)
dw_case(4,1,0,30,20,2,act=2)
for tx,ty in [(1,0),(0,1)]:
    dw_case(4,tx,ty,20,20,2)
for tx,ty in [(1,0),(1,2),(0,1),(2,1)]:
    dw_case(3,tx,ty,30,30,2)
dw_case(4,0,0,2,3,2)
dw_case(4,0,0,3,2,2)

begin("PW extremal positive accumulator")
for i in range(32):load(100+i,[[-128]*10 for _ in range(10)]);weight(i,-32768)
finish_expected(instruction(channels=32),[[32*128*32768]*10 for _ in range(10)])

begin("PW accumulation split across instructions")
tile=[[r*10+c-50 for c in range(10)] for r in range(10)]
load(100,tile);load(101,tile);weight(0,128);weight(1,-64)
before=[[-37]*10 for _ in range(10)];load(900,before)
emit(3,data=instruction(more=1,rounding=1));emit(4);emit(5,900,data=pack(before))
finish_expected(instruction(src=101,param=1,keep=1,rounding=1),
                [[v*64+128 for v in row] for row in tile])

begin("FIFO queued commands preserve execution and write order")
for i in range(4):
    load(100+i,[[i*11+r+c for c in range(10)] for r in range(10)])
weight(0,256)
for i in range(4):emit(3,data=instruction(src=100+i,dst=900+i))
for i in range(4):emit(4)
for i in range(4):emit(5,900+i,data=pack([[i*11+r+c for c in range(10)] for r in range(10)]))

for name,cmd in [
    ("reserved bits",instruction()|(1<<100)),
    ("source overflow",instruction(src=1023,channels=2)),
    ("parameter overflow",instruction(param=4095,channels=2)),
    ("DW unknown kernel",instruction(op=2,kernel=7)),
    ("insufficient padding",instruction(op=2,kernel=4,pad=2,width=1,edges=15)),
    ("pool full write",instruction(pool=1)),
    ("invalid continuation",instruction(keep=1)),
]:
    begin("reject "+name);emit(3,data=cmd);emit(4,1)
begin("DW neighbor address overflow")
emit(3,data=instruction(op=2,src=1,kernel=3));emit(4,2)
begin("NOP")
emit(3,data=instruction(op=3));emit(4)

ROOT.joinpath("vectors.txt").write_text("\n".join(lines)+"\n",encoding="ascii")
ROOT.joinpath("cases.json").write_text(json.dumps(cases,ensure_ascii=False,indent=2)+"\n",encoding="utf8")
print(f"Generated {len(cases)} deterministic cases, {len(lines)} transactions")
