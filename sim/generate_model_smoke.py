"""Actual epoch11 parameters through the 32-bit bus, native RTL and mapped gates."""
from pathlib import Path
import numpy as np
import sys
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from mn_codec import Instruction,Operation,Activation
from cyclegan_host import ArrayCore
model=ROOT/'build/cyclegan_model'
words=[int(v,16) for v in (model/'generator_params_q88.mem').read_text().split()]
words=[v-65536 if v>=32768 else v for v in words]
lut=[int(v,16) for v in (ROOT/'rtl/mn_tanh_u8.mem').read_text().split()]
core=ArrayCore(words,lut)
lines=[]
def packed(tile):
    value=0
    for r in range(10):
        for c in range(10):
            index=((r//5)*2+c//5)*25+(r%5)*5+c%5
            value|=(int(tile[r,c])&255)<<(index*8)
    return value
def emit(op,address=0,aux=0,data=0):lines.append(f'{op} {address:x} {aux:x} {data:0200x}')
for ch in range(3):
    tile=((np.arange(100).reshape(10,10)*7+ch*19)%127)-63
    core.write_tile(100+ch,tile);emit(1,100+ch,15,packed(tile))
commands=[
    Instruction(Operation.DW,src=100,dst=900,parameter=0,kernel=3,padding=2,pad_width=1,edges=15,rounding=True),
    Instruction(Operation.PW,src=100,dst=1350,parameter=27,channels=3,rounding=True),
    Instruction(Operation.NORM,src=1350,dst=1351,parameter=51,activation=Activation.RELU,rounding=True),
    Instruction(Operation.CONV,src=100,dst=1352,parameter=20427,kernel=5,tanh=True),
    Instruction(Operation.ADD,src=1350,dst=1353,parameter=1351),
]
for case,cmd in enumerate(commands,1):
    emit(8,case);core.execute(cmd);emit(3,data=cmd.encode());emit(4)
    emit(5,cmd.dst,data=packed(core.read_tile(cmd.dst)))
(ROOT/'build/sim/model_smoke.txt').write_text('\n'.join(lines)+'\n')
print('MODEL_SMOKE_VECTORS_PASS',len(commands),'commands with actual epoch11 weights')
