"""Residual-only same-frame IN assets; fixed encoder/decoder references are retained."""
from pathlib import Path
import json,shutil,zlib
import numpy as np
import prepare_encoder_deployment as base
ROOT=base.ROOT

def assets():
    model=ROOT/'build/instance_residual_model'
    raw=(model/'generator_norm_gamma.mem').read_text().split()
    words=[int(v,16) for v in raw[160:1312]]
    assert len(words)==1152
    text='// Raw Q8.8 gamma,beta for eighteen residual IN points; 3 BRAM.\n'
    text+='module mn_instance_norm_gamma(input wire clk,rd_en,input wire [10:0] addr,output wire [15:0] data);\nwire [15:0] q[0:2];\n'
    for bank in range(3):
        image=sum(v<<(16*i) for i,v in enumerate(words[bank*512:(bank+1)*512]))
        init=',\n'.join(f".INIT_{i:X}(256'h{(image>>(256*i))&((1<<256)-1):064x})" for i in range(40))
        text+=f'EFX_RAM10 #(.READ_WIDTH(16),.WRITE_WIDTH(16),.OUTPUT_REG(0),.RESET_RAM("SYNC"),\n{init}) b{bank}(\n'
        text+=f".RCLK(clk),.RE(rd_en),.RST(addr[10:9]!={bank}),.RADDREN(1'b1),.RADDR(addr[8:0]),.RDATA(q[{bank}]),\n"
        text+=".WCLK(clk),.WCLKE(1'b0),.WADDREN(1'b0),.WE(2'b00),.WADDR(9'd0),.WDATA(16'd0));\n"
    text+='assign data=q[0]|q[1]|q[2];\nendmodule\n'
    (ROOT/'rtl/mn_instance_norm_gamma.sv').write_text(text,encoding='ascii')
    out=ROOT/'build/instance_residual_verified'
    for suffix in ('','_inverted'):
        dest=out/('vectors'+suffix);dest.mkdir(parents=True,exist_ok=True)
        source=model/('vectors'+suffix)
        for f in source.iterdir():
            if f.is_file():shutil.copy2(f,dest/f.name)
        for i in range(1,4):
            shutil.copy2(source/f'encoder{i}_q44_tiles.mem',dest/f'stage{i}_tiles.mem')
            shutil.copy2(source/f'stage{i}_q44_tiles.mem',dest/f'decoder{i}_tiles.mem')
        for i in range(1,10):shutil.copy2(source/f'block{i}_q44_tiles.mem',dest/f'block{i}_tiles.mem')
        rgb=np.frombuffer((source/'frame_rgbx.bin').read_bytes(),dtype=np.uint8).reshape(240,320,4)[:,:,:3]
        stream=((rgb.astype(np.int16)-124)>>3).astype(np.int8).reshape(24,10,32,10,3).transpose(0,2,1,4,3).tobytes()
        (dest/'input_crc.mem').write_text(f'{zlib.crc32(stream):08x}\n')
        coefficients=json.loads((source/'live_normalization.json').read_text())['coefficients']
        assert len(coefficients)==18 and [v['id'] for v in coefficients]==list(range(5,23))
        (dest/'coefficients.mem').write_text(''.join(f'{a&65535:04x}\n{b&65535:04x}\n' for r in coefficients for a,b in zip(r['a'],r['b'])))
    print('INSTANCE_RESIDUAL_ASSETS_PASS 18 points, 576 channels, same-frame reference',flush=True)

if __name__=='__main__':assets()
