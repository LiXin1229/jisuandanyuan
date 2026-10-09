"""Deterministic integer golden vectors; no dependency beyond Conda Python."""
from pathlib import Path
import json
import random
import argparse

cli=argparse.ArgumentParser(description=__doc__)
cli.add_argument('--exhaustive-add',action='store_true',help='Slow native-DSP check of all 65536 operand pairs')
args=cli.parse_args()

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
                rounding=0, keep=0, more=0, stride2=0, ring=0, top=0, bottom=0,tanh=0):
    fields = [(op, 0), (src & 1023, 4), (dst & 1023, 14), (param & 4095, 24), (channels-1, 36),
              (kernel, 41), (act, 44), (pool, 46), (write, 47), (pad, 50),
              (width, 52), (edges, 54), (vw-1, 58), (vh-1, 62),
              (tile_pitch, 66), (row_pitch, 76), (rounding, 86),
              (keep, 87), (more, 88), (stride2, 89), (src>>10,90), (dst>>10,91),
              (param>>12,92),(ring,95), (top,96), (bottom,107),(tanh,118)]
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
    ("reserved bits",instruction()|(1<<127)),
    ("source overflow",instruction(src=1486,channels=2)),
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

# V2 extensions use an independently encoded command and whole-image golden.
for source, destination, channels in [(1040,1350,3),(508,1100,8)]:
    begin(f"V2 PW src={source} dst={destination}, crossing cache banks")
    tiles=[[[rng.randrange(-64,65) for _ in range(10)] for _ in range(10)]
           for _ in range(channels)]
    weights=[rng.randrange(-128,129) for _ in range(channels)]
    for ch in range(channels):load(source+ch,tiles[ch]);weight(ch,weights[ch])
    emit(3,data=instruction(src=source,dst=destination,channels=channels,rounding=1))
    emit(4)
    expected=[[quant(128+sum(tiles[ch][r][c]*weights[ch] for ch in range(channels)),0)
               for c in range(10)] for r in range(10)]
    emit(5,destination,data=pack(expected))

for kernel in (3,4):
    for ty in (0,2,4):
        begin(f"V2 DW ring, kernel={kernel}, logical row={ty}")
        kh,kw,ay,ax=kernels[kernel];tx=1;height=50;width=30
        base=1100;pitch=2;row_stride=12
        def ring_address(y,x):return base+(y%3)*row_stride+x*pitch
        for dy in (-1,0,1):
            for dx in (-1,0,1):
                y,x=ty+dy,tx+dx
                if not 0<=y<5:continue
                load(ring_address(y,x),[[image_pixel(y*10+r,x*10+c)
                                         for c in range(10)] for r in range(10)])
        weights=[rng.randrange(-90,91) for _ in range(kh*kw)]
        for i,w in enumerate(weights):weight(2000+i,w)
        edge=(4 if ty==0 else 0)|(8 if ty==4 else 0)
        cmd=instruction(op=2,src=ring_address(ty,tx),dst=1350,param=2000,kernel=kernel,
                        pad=2,width=3 if kernel==4 else 1,edges=edge,tile_pitch=pitch,
                        row_pitch=row_stride,rounding=1,ring=1,
                        top=ring_address(max(0,ty-1),tx),bottom=ring_address(min(4,ty+1),tx))
        expected=[]
        for r in range(10):
            row=[]
            for c in range(10):
                total=128
                for ky in range(kh):
                    for kx in range(kw):
                        y=reflected(ty*10+r+ky-ay,height)
                        x=reflected(tx*10+c+kx-ax,width)
                        total+=image_pixel(y,x)*weights[ky*kw+kx]
                row.append(quant(total,0))
            expected.append(row)
        emit(3,data=cmd);emit(4);emit(5,1350,data=pack(expected))

add_codes=list(range(65536)) if args.exhaustive_add else [
    (a+128)*256+b for a in (-128,-127,-96,-16,-1,0,1,16,96,126,127) for b in range(256)]
begin("ADD signed8 operand boundaries, shared DSP accumulator")
for start in range(0,len(add_codes),100):
    pairs=[divmod(add_codes[min(start+i,len(add_codes)-1)],256) for i in range(100)]
    left=[[pairs[r*10+c][0]-128 for c in range(10)] for r in range(10)]
    right=[[pairs[r*10+c][1]-128 for c in range(10)] for r in range(10)]
    load(1040,left);load(1041,right)
    emit(3,data=instruction(op=5,src=1040,dst=1350,param=1041,rounding=1))
    emit(4)
    result=[[max(-128,min(127,left[r][c]+right[r][c])) for c in range(10)] for r in range(10)]
    emit(5,1350,data=pack(result))

for kernel,cin,tanh in [(5,3,0),(0,3,0),(1,3,0),(2,3,0),(3,3,0),(4,8,1)]:
    begin(f"CONV raw continuation, kernel={kernel}, cin={cin}, tanh={tanh}")
    kh,kw,ay,ax=(1,1,0,0) if kernel==5 else kernels[kernel]
    total=[[0]*10 for _ in range(10)]
    for channel in range(cin):
        def value(y,x):return ((y*31+x*17+channel*13)%121)-60
        for dy in (-1,0):
            for dx in (-1,0):
                load(100+dy*12+dx*2,[[value((1+dy)*10+r,(1+dx)*10+c)
                                      for c in range(10)] for r in range(10)])
        weights=[rng.randrange(-180,181) for _ in range(kh*kw)]
        for k,w in enumerate(weights):weight(1000+channel*kh*kw+k,w)
        for r in range(10):
            for c in range(10):
                for kr in range(kh):
                    for kc in range(kw):
                        y,x=10+r+kr-ay,10+c+kc-ax
                        if y>=20 or x>=20:
                            if kernel==4:y=reflected(y,20);x=reflected(x,20)
                            else:continue
                        total[r][c]+=value(y,x)*weights[kr*kw+kc]
        if channel==0:load(1350,[[-37]*10 for _ in range(10)])
        emit(3,data=instruction(op=4,src=100,dst=1350,param=1000+channel*kh*kw,
                               kernel=kernel,rounding=not tanh,keep=channel!=0,more=channel!=cin-1,
                               pad=2 if kernel==4 else 1,width=3 if kernel==4 else 1,
                               edges=10 if kernel!=5 else 0,tanh=tanh))
        emit(4)
        if channel!=cin-1:emit(5,1350,data=pack([[-37]*10 for _ in range(10)]))
    if tanh:
        lut=[int(v,16) for v in (ROOT.parent/'rtl/mn_tanh_u8.mem').read_text().split()]
        result=[[lut[max(-2048,min(2047,(v+8)>>4))+2048] for v in row] for row in total]
    else:result=[[quant(v+128,0) for v in row] for row in total]
    emit(5,1350,data=pack(result))

begin("Invalid spatial continuation preserves the live raw accumulator")
tile=[[r*7-c*5 for c in range(10)] for r in range(10)]
load(100,tile);load(101,tile);load(1350,[[-37]*10 for _ in range(10)]);weight(1000,128)
emit(3,data=instruction(op=4,src=100,dst=1350,param=1000,kernel=5,rounding=1,more=1));emit(4)
emit(3,data=instruction(op=4,src=1,dst=1350,param=1000,kernel=3,rounding=1,keep=1));emit(4,2)
emit(3,data=instruction(op=4,src=101,dst=1350,param=1000,kernel=5,rounding=1,keep=1));emit(4)
emit(5,1350,data=pack(tile))

# Full-tile fast3 integration, including all four-edge combinations. The
# reference samples an image, independently of the hardware's read/tap order.
for pad in (1,2):
    for edge in range(16):
        begin(f"Fast3 all edges={edge}, pad={pad}, full tile")
        tx=0 if edge&1 else 1;ty=0 if edge&4 else 1
        nx=tx+1 if edge&2 else tx+2;ny=ty+1 if edge&8 else ty+2
        width=nx*10;height=ny*10
        def location(y,x):return 1100+y*12+x*2
        for y in range(ny):
            for x in range(nx):
                load(location(y,x),[[image_pixel(y*10+r,x*10+c) for c in range(10)] for r in range(10)])
        weights=[-31,17,29,-13,37,-23,19,-41,11]
        for k,w in enumerate(weights):weight(1700+k,w)
        result=[]
        for r in range(10):
            row=[]
            for c in range(10):
                total=128
                for kr in range(3):
                    for kc in range(3):
                        y=ty*10+r+kr-1;x=tx*10+c+kc-1
                        if not 0<=y<height or not 0<=x<width:
                            if pad==1:continue
                            y=reflected(y,height);x=reflected(x,width)
                        total+=image_pixel(y,x)*weights[kr*3+kc]
                row.append(quant(total,0))
            result.append(row)
        emit(3,data=instruction(op=2,src=location(ty,tx),dst=1350,param=1700,kernel=3,
                               rounding=1,pad=pad,width=1,edges=edge))
        emit(4);emit(5,1350,data=pack(result))

ROOT.joinpath("vectors.txt").write_text("\n".join(lines)+"\n",encoding="ascii")
ROOT.joinpath("cases.json").write_text(json.dumps(cases,ensure_ascii=False,indent=2)+"\n",encoding="utf8")
print(f"Generated {len(cases)} deterministic cases, {len(lines)} transactions")
