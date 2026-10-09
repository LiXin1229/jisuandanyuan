"""Host-side ISA and tile codec. All values here are integer raw fixed point."""
from dataclasses import dataclass
from enum import IntEnum
import argparse
import json


class Operation(IntEnum):
    PW=0
    NORM=1
    DW=2
    NOP=3


class Activation(IntEnum):
    NONE=0
    RELU=1
    RELU6=2


KERNELS={"1x2":0,"2x1":1,"2x2":2,"3x3":3,"7x7":4}


@dataclass(frozen=True)
class Instruction:
    operation: Operation=Operation.PW
    src: int=0
    dst: int=0
    parameter: int=0
    channels: int=1
    kernel: int=3
    activation: Activation=Activation.NONE
    pool: bool=False
    write: int=0
    padding: int=0
    pad_width: int=0
    edges: int=0
    valid_w: int=10
    valid_h: int=10
    tile_pitch: int=1
    row_pitch: int=1
    rounding: bool=False
    keep_acc: bool=False
    more_acc: bool=False
    stride2: bool=False

    def encode(self):
        if self.operation not in tuple(Operation):
            raise ValueError("Reserved operation code")
        if not 1<=self.channels<=32 or not 1<=self.valid_w<=10 or not 1<=self.valid_h<=10:
            raise ValueError("channels must be 1..32; tile dimensions must be 1..10")
        if self.operation==Operation.NORM and self.channels!=1:
            raise ValueError("NORM accepts one channel")
        if self.pool and self.stride2:
            raise ValueError("pool and convolution decimation are mutually exclusive")
        if (self.pool or self.stride2) and self.write==0:
            raise ValueError("25-pixel output needs a destination quadrant 1..4")
        if (self.keep_acc or self.more_acc) and self.operation!=Operation.PW:
            raise ValueError("split accumulation is a PW mode")
        if self.operation==Operation.PW and self.src+self.channels>1024:
            raise ValueError("PW source range exceeds cache")
        if self.operation==Operation.DW:
            if self.channels!=1:
                raise ValueError("DW instruction operates on one channel")
            if self.kernel not in KERNELS.values() or not self.tile_pitch or not self.row_pitch:
                raise ValueError("DW needs a supported kernel and nonzero local pitches")
            if self.edges and (self.padding==0 or self.pad_width not in (1,3) or
                               self.kernel==4 and self.pad_width!=3):
                raise ValueError("boundary padding must cover the kernel halo")
        count=([2,2,4,9,49][self.kernel] if self.operation==Operation.DW else
               2 if self.operation==Operation.NORM else self.channels)
        if self.operation!=Operation.NOP and self.parameter+count>4096:
            raise ValueError("parameter range exceeds RAM")
        fields=[(self.operation,0,4),(self.src,4,10),(self.dst,14,10),
                (self.parameter,24,12),(self.channels-1,36,5),(self.kernel,41,3),
                (self.activation,44,2),(self.pool,46,1),(self.write,47,3),
                (self.padding,50,2),(self.pad_width,52,2),(self.edges,54,4),
                (self.valid_w-1,58,4),(self.valid_h-1,62,4),
                (self.tile_pitch,66,10),(self.row_pitch,76,10),
                (self.rounding,86,1),(self.keep_acc,87,1),(self.more_acc,88,1),
                (self.stride2,89,1)]
        word=0
        for value,shift,bits in fields:
            if not 0<=value<1<<bits:
                raise ValueError(f"Field at bit {shift} exceeds {bits} bits")
            word|=int(value)<<shift
        if self.activation>2 or self.write>4 or self.padding>2:
            raise ValueError("Reserved activation, write, or padding code")
        return word

    def bus_words(self):
        word=self.encode()
        return [(word>>(i*32))&0xffffffff for i in range(4)]


def pack_tile(pixels):
    if len(pixels)!=100 or any(not -128<=v<=127 for v in pixels):
        raise ValueError("Tile needs 100 signed8 raw pixels in row-major order")
    word=0
    for index,value in enumerate(pixels):
        r,c=divmod(index,10)
        packed=((r//5)*2+c//5)*25+(r%5)*5+c%5
        word|=(value&255)<<(packed*8)
    return word


def unpack_tile(word):
    pixels=[]
    for r in range(10):
        for c in range(10):
            packed=((r//5)*2+c//5)*25+(r%5)*5+c%5
            value=(word>>(packed*8))&255
            pixels.append(value-256 if value&128 else value)
    return pixels


if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("--operation",choices=[x.name.lower() for x in Operation],default="pw")
    p.add_argument("--src",type=int,default=100);p.add_argument("--dst",type=int,default=900)
    p.add_argument("--parameter",type=int,default=0);p.add_argument("--channels",type=int,default=1)
    p.add_argument("--kernel",choices=KERNELS,default="3x3")
    p.add_argument("--activation",choices=[x.name.lower() for x in Activation],default="none")
    p.add_argument("--padding",choices=["none","zero","reflect"],default="none")
    p.add_argument("--pad-width",type=int,default=0);p.add_argument("--edges",type=lambda s:int(s,0),default=0)
    p.add_argument("--tile-pitch",type=int,default=1);p.add_argument("--row-pitch",type=int,default=1)
    p.add_argument("--valid-w",type=int,default=10);p.add_argument("--valid-h",type=int,default=10)
    p.add_argument("--write",type=int,default=0)
    for flag in ["pool","rounding","keep-acc","more-acc","stride2"]:p.add_argument("--"+flag,action="store_true")
    a=p.parse_args()
    inst=Instruction(Operation[a.operation.upper()],a.src,a.dst,a.parameter,a.channels,
        KERNELS[a.kernel],Activation[a.activation.upper()],a.pool,a.write,
        ["none","zero","reflect"].index(a.padding),a.pad_width,a.edges,a.valid_w,a.valid_h,
        a.tile_pitch,a.row_pitch,a.rounding,a.keep_acc,a.more_acc,a.stride2)
    print(json.dumps({"instruction":f"{inst.encode():032x}",
                     "bus_words_low_first":[f"{w:08x}" for w in inst.bus_words()]},indent=2))
