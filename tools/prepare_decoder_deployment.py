"""Exact stage-3 prefix ROM and the common DDR/JTAG board shell."""
from pathlib import Path
import argparse,json,shutil
import prepare_encoder_deployment as encoder
ROOT=encoder.ROOT

def assets():
    words=[int(x,16) for x in (ROOT/'build/cyclegan_model/generator_params_q88.mem').read_text().split()][:20427]
    assert len(words)==20427
    exceptions=[(i,v) for i,v in enumerate(words) if ((v>>10)&63)!=(63 if v&1024 else 0)]
    text='// Exact epoch11 words 0..20426: 20 low planes + 3 sign planes.\n'
    text+='module mn_decoder_rom(input wire clk,rd_en,input wire [14:0] addr,output wire [15:0] data);\nwire [9:0] lo[0:19];wire hi[0:2];\n'
    for bank in range(23):
        low=bank<20;width=10 if low else 1;count=1024 if low else 8192
        offset=bank*1024 if low else (bank-20)*8192
        values=[(v&1023) if low else ((v>>10)&1) for v in words[offset:offset+count]]
        image=sum(v<<(width*i) for i,v in enumerate(values))
        init=',\n'.join(f'.INIT_{i:X}(256\'h{(image>>(256*i))&((1<<256)-1):064x})' for i in range(40))
        text+=f'EFX_RAM10 #(.READ_WIDTH({width}),.WRITE_WIDTH({width}),.OUTPUT_REG(0),.RESET_RAM("SYNC"),\n{init}) b{bank}(\n'
        select=f'addr[14:10]!={bank}' if low else f'addr[14:13]!={bank-20}'
        a=9 if low else 12;q=f'lo[{bank}]' if low else f'hi[{bank-20}]'
        text+=f'.RCLK(clk),.RE(rd_en),.RST({select}),.RADDREN(1\'b1),.RADDR(addr[{a}:0]),.RDATA({q}),\n'
        text+=f'.WCLK(clk),.WCLKE(1\'b0),.WADDREN(1\'b0),.WE(2\'b00),.WADDR({a+1}\'d0),.WDATA({width}\'d0));\n'
    text+='reg exceptional;reg [15:0] exception_data;\nalways @(posedge clk) if(rd_en) begin\nexceptional<=1;\ncase(addr)\n'
    text+=''.join(f"15'd{i}:exception_data<=16'h{v:04x};\n" for i,v in exceptions)
    text+='default:begin exceptional<=0;exception_data<=0;end\nendcase\nend\n'
    text+='wire [9:0] low_word='+'|'.join(f'lo[{i}]' for i in range(20))+';\n'
    text+='assign data=exceptional ? exception_data : {{6{hi[0]|hi[1]|hi[2]}},low_word};\nendmodule\n'
    (ROOT/'rtl/mn_decoder_rom.sv').write_text(text,encoding='ascii')
    out=ROOT/'build/stage3';out.mkdir(parents=True,exist_ok=True)
    for suffix in ('','_inverted'):
        dest=out/('vectors'+suffix);dest.mkdir(exist_ok=True)
        source=ROOT/('build/cyclegan_model/vectors'+suffix)
        for name in ('frame_rgbx.mem',)+tuple(f'block{i}_q44_tiles.mem' for i in range(1,10)):
            shutil.copy2(source/name,dest/name)
        for i in range(1,4):
            shutil.copy2(source/f'stage{i}_q44_tiles.mem',dest/f'decoder{i}_tiles.mem')
    (out/'rom_layout.json').write_text(json.dumps(dict(words=len(words),bram=23,exceptions=exceptions),indent=2))
    print('STAGE3_ASSETS_PASS 20427 exact parameters, 23 ROM BRAM, three transpose references')

if __name__=='__main__':
    ap=argparse.ArgumentParser();ap.add_argument('--assets',action='store_true');ap.add_argument('--board',type=Path);args=ap.parse_args()
    if args.assets:assets()
    if args.board:encoder.board(args.board,residual=True,decoder=True)
