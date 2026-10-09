"""Epoch11 tile scheduler for the extended compute-unit bus.

BusCore accepts a board-specific transport exposing write_word/read_word. Full
feature maps live in host memory (or can be provided by an external-memory DMA).
ArrayCore independently executes the encoded instructions for schedule validation;
this is an integer instruction model, not an RTL/board simulation.
"""
from __future__ import annotations
import argparse
from collections import Counter
import json
from pathlib import Path
import time

import numpy as np
from mn_codec import Instruction, Operation, Activation, pack_tile, unpack_tile

ROOT = Path(__file__).resolve().parents[1]


class BusCore:
    """Synchronous word-addressed transport; read/write methods must honor ready.

    One instruction is outstanding. Cache reads use the bus's shared tile snapshot.
    MODEL_PARAMS=1 must be selected; parameter writes are not used by this driver.
    """
    def __init__(self, transport, timeout=30):
        self.transport, self.timeout = transport, timeout
        self.counts = Counter()

    def wait_idle(self):
        deadline = time.monotonic() + self.timeout
        while True:
            status = self.transport.read_word(0)
            if status & 4 and not status & 1 and not (status >> 9) & 7:
                return status
            if time.monotonic() > deadline:
                raise TimeoutError('Compute-unit memory/FIFO did not become idle')

    def write_tile(self, address, tile):
        self.wait_idle()
        word = pack_tile([int(v) for v in np.asarray(tile).flat])
        self.transport.write_word(1, address)
        self.transport.write_word(2, 15)
        for i in range(25):
            self.transport.write_word(32 + i, (word >> (32 * i)) & 0xffffffff)
        self.transport.write_word(3, 1)
        self.counts['tile_writes'] += 1

    def read_tile(self, address):
        self.wait_idle()
        self.transport.write_word(1, address)
        self.transport.write_word(4, 1)
        # An ordinary bus cycle after the read request lets the synchronous
        # cache response enter staging before the first snapshot word is read.
        self.transport.read_word(0)
        word = sum(int(self.transport.read_word(32 + i)) << (32 * i) for i in range(25))
        self.counts['tile_reads'] += 1
        return np.array(unpack_tile(word), dtype=np.int64).reshape(10, 10)

    def write_row(self, address, row, pixels):
        """Write one channel's 10 pixels; update only four native 20-bit slices."""
        if not 0<=address<1487 or not 0<=row<10 or len(pixels)!=10:
            raise ValueError('Row write requires a feature address, row 0..9 and 10 pixels')
        if any(not -128<=int(v)<=127 for v in pixels):raise ValueError('Row pixels must be signed8')
        self.wait_idle()
        words={};mask=0
        for c,pixel in enumerate(pixels):
            packed=((row//5)*2+c//5)*25+(row%5)*5+c%5
            bit=packed*8;word=bit//32
            words[word]=words.get(word,0)|((int(pixel)&255)<<(bit%32))
        for q in (2*(row//5),2*(row//5)+1):
            mask|=3<<(q*10+2*(row%5))
        self.transport.write_word(1,address)
        for index,data in words.items():self.transport.write_word(32+index,data)
        self.transport.write_word(12,mask&0xffffffff)
        self.transport.write_word(13,mask>>32)
        self.transport.write_word(3,1)
        self.counts['row_writes']+=1

    def execute(self, command):
        self.wait_idle()
        self.transport.write_word(0, 2)
        for i, word in enumerate(command.bus_words()):
            self.transport.write_word(8 + i, word)
        self.transport.write_word(7, 1)
        deadline = time.monotonic() + self.timeout
        while True:
            status = self.transport.read_word(0)
            if status & 2:
                error = (status >> 4) & 15
                if error:
                    raise RuntimeError(f'Instruction {command.encode():032x} failed with code {error}')
                break
            if time.monotonic() > deadline:
                raise TimeoutError('Instruction did not finish')
        self.counts[command.operation.name] += 1


class ArrayCore:
    """Functional model decodes the actual 128-bit command rather than its object."""
    def __init__(self, parameters, lut, trace=None):
        self.parameters = np.asarray(parameters, dtype=np.int64)
        self.lut = np.asarray(lut, dtype=np.int64)
        self.cache = {}
        self.acc = np.zeros((10, 10), dtype=np.int64)
        self.live, self.acc_dst, self.acc_round, self.terms = False, 0, False, 0
        self.counts = Counter()
        self.trace = trace

    def write_tile(self, address, tile):
        assert 0 <= address < 1487
        tile = np.asarray(tile, dtype=np.int64)
        assert tile.shape == (10, 10) and np.all((-128 <= tile) & (tile <= 127))
        self.cache[address] = tile.copy()
        self.counts['tile_writes'] += 1

    def read_tile(self, address):
        self.counts['tile_reads'] += 1
        return self.cache[address].copy()

    def write_row(self,address,row,pixels):
        assert 1024<=address<1487 and 0<=row<10
        tile=self.cache.get(address,np.zeros((10,10),dtype=np.int64)).copy()
        tile[row,:]=pixels
        assert np.all((-128<=tile)&(tile<=127))
        self.cache[address]=tile
        self.counts['row_writes']+=1

    def spatial(self, src, pitch, stride, kh, kw, ay, ax, edges, padding,
                vw, vh, ring, top, bottom):
        # Source rectangle is assembled once; padding maps coordinates around
        # the current tile, independently of RTL's halo-copy/window RAM flow.
        block = np.zeros((30, 30), dtype=np.int64)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                if (dy == -1 and edges & 4) or (dy == 1 and edges & 8) or \
                   (dx == -1 and edges & 1) or (dx == 1 and edges & 2):
                    continue
                base = top if ring and dy == -1 else bottom if ring and dy == 1 else src + dy * stride
                address = base + dx * pitch
                if address in self.cache:
                    block[(dy+1)*10:(dy+2)*10, (dx+1)*10:(dx+2)*10] = self.cache[address]
                elif dy == 0 and dx == 0:
                    raise RuntimeError(f'Uninitialized source tile {address}')
        coords = np.arange(-3, 13)
        def mapped(extent, lower, upper):
            out = ((coords < 0) & bool(lower)) | ((coords >= extent) & bool(upper))
            loc = coords.copy()
            if padding == 2:
                if lower and upper:
                    if extent == 1:loc[:] = 0
                    else:
                        period = 2 * (extent - 1)
                        loc %= period
                        loc = np.minimum(loc, period - loc)
                else:
                    if lower:loc = np.where(loc < 0, -loc, loc)
                    if upper:loc = np.where(loc >= extent, 2*extent-2-loc, loc)
            return loc + 10, out if padding != 2 else np.zeros(16, dtype=bool)
        ys, yz = mapped(vh, edges & 4, edges & 8)
        xs, xz = mapped(vw, edges & 1, edges & 2)
        halo = block[ys[:, None], xs[None, :]]
        halo[yz, :] = 0;halo[:, xz] = 0
        return [halo[3-ay+r:13-ay+r, 3-ax+c:13-ax+c] for r in range(kh) for c in range(kw)]

    def execute(self, command):
        word = command.encode()
        f = lambda shift, bits: (word >> shift) & ((1 << bits) - 1)
        op = f(0, 4);src = f(4, 10) | (f(90, 1) << 10)
        dst = f(14, 10) | (f(91, 1) << 10)
        param = f(24, 12) | (f(92, 3) << 12)
        cin, kernel, activation = f(36, 5)+1, f(41, 3), f(44, 2)
        pool, write, padding, edges = f(46, 1), f(47, 3), f(50, 2), f(54, 4)
        vw, vh = f(58, 4)+1, f(62, 4)+1
        rounding, keep, more, tanh = f(86, 1), f(87, 1), f(88, 1), f(118, 1)
        if keep:
            assert self.live and dst == self.acc_dst and rounding == self.acc_round
        else:
            self.acc[:] = 128 * rounding
            self.terms = 0
        if op == Operation.PW:
            for ch in range(cin):self.acc += self.cache[src+ch] * self.parameters[param+ch]
            self.terms += cin
        elif op == Operation.NORM:
            self.acc += self.cache[src] * self.parameters[param] + 16*self.parameters[param+1]
        elif op == Operation.ADD:
            self.acc += (self.cache[src] + self.cache[param]) * 256
        elif op in (Operation.DW, Operation.CONV):
            kh, kw, ay, ax = [(1,2,0,0),(2,1,0,0),(2,2,0,0),(3,3,1,1),(7,7,3,3),(1,1,0,0)][kernel]
            windows = self.spatial(src, f(66,10), f(76,10), kh, kw, ay, ax,
                                   edges, padding, vw, vh, f(95,1), f(96,11), f(107,11))
            for k, data in enumerate(windows):self.acc += data * self.parameters[param+k]
            self.terms += kh*kw
        else:
            raise ValueError(f'Unsupported schedule operation {op}')
        assert np.all((-2**31 <= self.acc) & (self.acc < 2**31))
        if more:
            self.live, self.acc_dst, self.acc_round = True, dst, rounding
        else:
            self.live = False
            if tanh:
                out = self.lut[np.clip((self.acc + 8) >> 4, -2048, 2047)+2048]
                out = np.where(out >= 128, out - 256, out)
            else:
                out = np.clip(self.acc >> 8, -128, 127)
                if activation:out = np.maximum(out, 0)
                if activation == 2:out = np.minimum(out, 96)
                out[vh:, :] = 0;out[:, vw:] = 0
            if pool:
                out = out.reshape(5,2,5,2).max(axis=(1,3))
                out[vh//2:, :] = 0;out[:, vw//2:] = 0
            if write:
                qr, qc = divmod(write-1, 2)
                target = self.cache.get(dst, np.zeros((10,10), dtype=np.int64)).copy()
                target[qr*5:qr*5+5, qc*5:qc*5+5] = out if pool else out[qr*5:qr*5+5, qc*5:qc*5+5]
                out = target
            self.cache[dst] = out.copy()
        self.counts[Operation(op).name] += 1
        if self.trace:self.trace.write(json.dumps({'command':f'{word:032x}', 'operation':Operation(op).name})+'\n')


class GeneratorScheduler:
    """Fixed scratch allocation; each spatial job has at most 9*32 input tiles.

    This first deployment driver uses external feature storage and serialized
    jobs. It does not require all feature maps to be resident in the three banks.
    """
    def __init__(self, core, manifest):
        self.core, self.manifest = core, manifest
        self.layer_results = {}
        # Bank 2 serves streaming input tiles and reserves its tail for windows.
        # Maximum neighborhood is 9*32=288 addresses, disjoint from 1487..1535.
        self.input_base=1024

    def load_neighborhood(self, feature, ty, tx, stream_rows=False):
        cin, h, w = feature.shape
        for dy in (-1,0,1):
            for dx in (-1,0,1):
                y,x = ty+dy,tx+dx
                if not 0 <= y*10 < h or not 0 <= x*10 < w:continue
                for ch in range(cin):
                    tile = np.zeros((10,10),dtype=np.int64)
                    piece = feature[ch,y*10:y*10+10,x*10:x*10+10]
                    tile[:piece.shape[0],:piece.shape[1]] = piece
                    address=self.input_base+((dy+1)*3+dx+1)*cin+ch
                    if stream_rows:
                        for r in range(10):self.core.write_row(address,r,tile[r])
                    else:self.core.write_tile(address,tile)
        edges = int(tx==0) | (int((tx+1)*10>=w)<<1) | (int(ty==0)<<2) | (int((ty+1)*10>=h)<<3)
        return cin, min(10,w-tx*10), min(10,h-ty*10), edges

    def separable(self, feature, info, pool=False, residual=False):
        cin, h, w = feature.shape;cout = info['cout']
        output = np.zeros((cout,h//2 if pool else h,w//2 if pool else w),dtype=np.int64)
        stem = info.get('layer') == 1
        for ty in range((h+9)//10):
            for tx in range((w+9)//10):
                _,vw,vh,edges = self.load_neighborhood(feature,ty,tx,stream_rows=stem)
                for ch in range(cin):
                    self.core.execute(Instruction(Operation.DW,src=self.input_base+4*cin+ch,dst=512+ch,
                        parameter=info['dw']+9*ch,kernel=3,padding=2 if stem else 1,
                        pad_width=1,edges=edges,valid_w=vw,valid_h=vh,
                        tile_pitch=cin,row_pitch=3*cin,rounding=True))
                    if 'dw_bn' in info:
                        self.core.execute(Instruction(Operation.NORM,src=512+ch,dst=512+ch,
                            parameter=info['dw_bn']+2*ch,activation=Activation.RELU,
                            valid_w=vw,valid_h=vh,rounding=True))
                for co in range(cout):
                    self.core.execute(Instruction(Operation.PW,src=512,dst=640+co,
                        parameter=info['pw']+co*cin,channels=cin,
                        valid_w=vw,valid_h=vh,rounding=True))
                    self.core.execute(Instruction(Operation.NORM,src=640+co,dst=640+co,
                        parameter=info['pw_bn']+2*co,activation=Activation.RELU if stem else Activation.NONE,
                        pool=pool,write=1 if pool else 0,valid_w=vw,valid_h=vh,rounding=True))
                    if residual:
                        self.core.execute(Instruction(Operation.ADD,src=640+co,dst=640+co,
                            parameter=self.input_base+4*cin+co,valid_w=vw,valid_h=vh))
                    tile = self.core.read_tile(640+co)
                    oh,ow = (vh//2,vw//2) if pool else (vh,vw)
                    y,x = (ty*5,tx*5) if pool else (ty*10,tx*10)
                    output[co,y:y+oh,x:x+ow] = tile[:oh,:ow]
        return output

    def transpose(self, feature, info):
        cin,h,w = feature.shape;cout = info['cout']
        output = np.zeros((cout,2*h,2*w),dtype=np.int64)
        for ty in range((h+9)//10):
            for tx in range((w+9)//10):
                _,vw,vh,edges = self.load_neighborhood(feature,ty,tx)
                for co in range(cout):
                    patch = np.zeros((20,20),dtype=np.int64)
                    for phase,kernel,ntaps in [(0,5,1),(1,0,2),(2,1,2),(3,2,4)]:
                        phase_base = info['weight_base']+co*cin*9+[0,cin,3*cin,5*cin][phase]
                        phase_edges = edges & (2 if phase==1 else 8 if phase==2 else 10 if phase==3 else 0)
                        for ch in range(cin):
                            self.core.execute(Instruction(Operation.CONV,src=self.input_base+4*cin+ch,dst=640,
                                parameter=phase_base+ch*ntaps,kernel=kernel,
                                padding=1,pad_width=1,edges=phase_edges,valid_w=vw,valid_h=vh,
                                tile_pitch=cin,row_pitch=3*cin,rounding=True,
                                keep_acc=ch!=0,more_acc=ch!=cin-1))
                        self.core.execute(Instruction(Operation.NORM,src=640,dst=640,
                            parameter=info['bn_base']+co*2,activation=Activation.RELU,
                            valid_w=vw,valid_h=vh,rounding=True))
                        patch[phase//2::2,phase%2::2] = self.core.read_tile(640)
                    output[co,ty*20:ty*20+2*vh,tx*20:tx*20+2*vw] = patch[:2*vh,:2*vw]
        return output

    def final(self, feature):
        cin,h,w = feature.shape;info = self.manifest['output'];kernel = info['kernel']
        output = np.zeros((3,h,w),dtype=np.uint8)
        for ty in range((h+9)//10):
            for tx in range((w+9)//10):
                _,vw,vh,edges = self.load_neighborhood(feature,ty,tx)
                for co in range(3):
                    for ch in range(cin):
                        self.core.execute(Instruction(Operation.CONV,src=self.input_base+4*cin+ch,dst=640,
                            parameter=info['weight_base']+(co*cin+ch)*kernel*kernel,
                            kernel=4 if kernel==7 else 3,padding=2,pad_width=kernel//2,
                            edges=edges,valid_w=vw,valid_h=vh,tile_pitch=cin,row_pitch=3*cin,
                            keep_acc=ch!=0,more_acc=ch!=cin-1,tanh=True))
                    output[co,ty*10:ty*10+vh,tx*10:tx*10+vw] = (self.core.read_tile(640)[:vh,:vw]&255).astype(np.uint8)
        return output

    def run(self, rgb, verify=None):
        feature = ((np.asarray(rgb,dtype=np.int64)-124)>>3).transpose(2,0,1)
        assert feature.shape == (3,240,320), 'Deployment graph expects 320x240 RGB'
        def record(name, value):
            self.layer_results[name] = value
            if verify is not None:
                reference = np.load(verify/(name+'.npy'))
                if not np.array_equal(reference,value):
                    mismatch = int(np.count_nonzero(reference!=value))
                    raise AssertionError(f'{name}: {mismatch} mismatches, max={np.abs(reference.astype(np.int64)-value).max()}')
            print('LAYER_PASS' if verify is not None else 'LAYER_DONE',name,list(value.shape),flush=True)
        for i,info in enumerate(self.manifest['encoder']):
            feature = self.separable(feature,info,pool=True);record(f'encoder{i+1}_q44',feature)
        for i,info in enumerate(self.manifest['blocks']):
            feature = self.separable(feature,info,residual=True);record(f'block{i+1}_q44',feature)
        for i,info in enumerate(self.manifest['decoder']):
            feature = self.transpose(feature,info);record(f'stage{i+1}_q44',feature)
        result = self.final(feature);record('output_u8',result)
        return result


def main():
    from PIL import Image
    cli=argparse.ArgumentParser(description=__doc__)
    cli.add_argument('--model',type=Path,default=ROOT/'build/cyclegan_model')
    cli.add_argument('--inverted',action='store_true')
    cli.add_argument('--trace',type=Path)
    args=cli.parse_args()
    model=args.model.resolve();manifest=json.loads((model/'params_manifest.json').read_text())
    words=[int(v,16) for v in (model/'generator_params_q88.mem').read_text().split()]
    words=[v-65536 if v>=32768 else v for v in words]
    lut=[int(v,16) for v in (ROOT/'rtl/mn_tanh_u8.mem').read_text().split()]
    trace=args.trace.open('w') if args.trace else None
    try:
        core=ArrayCore(words,lut,trace)
        scheduler=GeneratorScheduler(core,manifest)
        reference=model/('vectors_inverted' if args.inverted else 'vectors')
        rgb=np.frombuffer((reference/'frame_rgbx.bin').read_bytes(),dtype=np.uint8).reshape(240,320,4)[:,:,:3]
        result=scheduler.run(rgb,verify=reference)
        destination=ROOT/'build/cyclegan_schedule';destination.mkdir(exist_ok=True)
        suffix='_inverted' if args.inverted else ''
        Image.fromarray(result.transpose(1,2,0)).save(destination/f'output{suffix}.png')
        record={'validation':'full encoded-instruction integer model; not RTL or FPGA',
                'checkpoint_sha256':manifest['checkpoint_sha256'],'counts':dict(core.counts),
                'layers_checked':len(scheduler.layer_results),'final_values_checked':result.size,
                'all_layers_equal':True,'feature_storage':'host memory',
                'cache_reserved_window_addresses':[1487,1535]}
        (destination/f'validation{suffix}.json').write_text(json.dumps(record,indent=2)+'\n')
        print('SCHEDULE_PASS',json.dumps(record),flush=True)
    finally:
        if trace:trace.close()


if __name__=='__main__':main()
