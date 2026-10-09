"""Reproducible stage-1 assets and board shell, derived from read-only pe10_10.

Run with bundled NumPy Python for --assets; Efinity Python for --board PATH.
Only the DDR/CDC/JTAG shell is reused. Arithmetic is the current mobilenet_unit.
"""
from pathlib import Path
import argparse, hashlib, json, os, shutil, sys,zlib
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
REF = Path(r'C:\Users\Administrator\Desktop\jisuan\pe10_10')
SOURCES = ['mn_cache.sv','mn_param_ram.sv','mn_instruction_fifo.sv','mn_dw_buffer_bram.sv',
           'mn_input_mux.sv','mn_pe_array.sv','mn_compact.sv','mn_postprocess.sv',
           'mn_model_rom.sv','mn_encoder_rom.sv','mn_tanh.sv','mobilenet_unit.sv',
           'cyclegan_rgb_loader.sv','cyclegan_encoder.sv','cyclegan_ddr_read_bridge.sv']

def assets():
    out=ROOT/'build/stage1';out.mkdir(parents=True,exist_ok=True)
    words=[int(x,16) for x in (ROOT/'build/cyclegan_model/generator_params_q88.mem').read_text().split()][:1067]
    text='// Generated from epoch11 Q8.8 words 0..1066; exact 3x512x16 ROM.\n'
    text+='module mn_encoder_rom(input wire clk,rd_en,input wire [14:0] addr,output wire [15:0] data);\n'
    text+='wire [15:0] q[0:2];\n'
    for bank in range(3):
        image=sum(v<<(16*i) for i,v in enumerate(words[bank*512:(bank+1)*512]))
        init=',\n'.join(f'.INIT_{i:X}(256\'h{(image>>(256*i))&((1<<256)-1):064x})' for i in range(40))
        text+=f'EFX_RAM10 #(.READ_WIDTH(16),.WRITE_WIDTH(16),.OUTPUT_REG(0),.RESET_RAM("SYNC"),\n{init}) b{bank}(\n'
        text+=f'.RCLK(clk),.RE(rd_en),.RST(addr[14:9]!={bank}),.RADDREN(1\'b1),.RADDR(addr[8:0]),.RDATA(q[{bank}]),\n'
        text+='.WCLK(clk),.WCLKE(1\'b0),.WADDREN(1\'b0),.WE(2\'b00),.WADDR(9\'d0),.WDATA(16\'d0));\n'
    text+='assign data=q[0]|q[1]|q[2];\nendmodule\n'
    (ROOT/'rtl/mn_encoder_rom.sv').write_text(text,encoding='ascii')
    loader=(REF/'generator/rtl/generator_input_tile_loader.v').read_text(encoding='utf8')
    loader=loader.replace('module generator_input_tile_loader','module cyclegan_rgb_loader')
    loader=loader.replace('(y%3)*96+channel*32+x','(y%3)*96+x*3+channel')
    loader=loader.replace('output wire cache_wr,','input wire cache_ready,output wire cache_wr,')
    loader=loader.replace('cache_wr=state==WRITE','cache_wr=state==WRITE && cache_ready')
    loader=loader.replace('rsp_ready=state==WRITE && channel==2','rsp_ready=state==WRITE && channel==2 && cache_ready')
    loader=loader.replace('(state==WRITE && channel<2)','(state==WRITE && channel<2 && cache_ready)')
    loader=loader.replace('WRITE:if(channel<2)','WRITE:if(!cache_ready) begin end else if(channel<2)')
    (ROOT/'rtl/cyclegan_rgb_loader.sv').write_text('// Derived from pe10_10/generator/rtl/generator_input_tile_loader.v.\n'+loader,encoding='utf8')
    import numpy as np
    for suffix in ('','_inverted'):
        src=ROOT/('build/cyclegan_model/vectors'+suffix);dest=out/('vectors'+suffix);dest.mkdir(exist_ok=True)
        shutil.copy2(src/'frame_rgbx.mem',dest/'frame_rgbx.mem')
        raw=np.frombuffer((src/'frame_rgbx.bin').read_bytes(),dtype=np.uint8).reshape(240,320,4)[:,:,:3].astype(np.int16)
        stream=((raw-124)>>3).astype(np.int8).reshape(24,10,32,10,3).transpose(0,2,1,4,3).tobytes()
        (dest/'input_crc.mem').write_text(f'{zlib.crc32(stream):08x}\n')
        for i in (1,2,3):
            act=np.load(src/f'encoder{i}_q44.npy');c,h,w=act.shape
            tiles=[]
            for ch in range(c):
                for y in range(0,h,10):
                    for x in range(0,w,10):
                        v=act[ch,y:y+10,x:x+10]
                        tiles.append(b''.join(v[r:r+5,k:k+5].astype(np.int8).tobytes() for r,k in [(0,0),(0,5),(5,0),(5,5)]))
            (dest/f'stage{i}_tiles.mem').write_text(''.join(f'{int.from_bytes(t,"little"):0200x}\n' for t in tiles))
    print('STAGE1_ASSETS_PASS 1067 exact parameters, 3 ROM BRAM, two reference frames')

def board(dest):
    dest=dest.resolve();dest.mkdir(parents=True,exist_ok=True)
    for name in SOURCES+['mn_isa.vh','mn_model_params_init.vh','mn_tanh_u8.mem']:
        shutil.copy2(ROOT/'rtl'/name,dest/name)
    (dest/'rtl').mkdir(exist_ok=True)
    shutil.copy2(ROOT/'rtl/mn_tanh_u8.mem',dest/'rtl/mn_tanh_u8.mem')
    for relative in ['encoder/rtl/frame_pingpong.v',
                     '04-1_Ti60_SC2210_HDMI_1080P60/src/axi/AXI4_AWARMux.v']:
        shutil.copy2(REF/relative,dest/Path(relative).name)
    ddr=REF/'04-1_Ti60_SC2210_HDMI_1080P60/ip/DdrCtrl'
    shutil.copytree(ddr,dest/'DdrCtrl',dirs_exist_ok=True)
    text=(REF/'encoder/rtl/encoder_board.v').read_text(encoding='utf8')
    text=text.replace('module encoder_board (','module cyclegan_encoder_board (').replace('encoder_core u_core','cyclegan_encoder u_core')
    text=text.replace('ddr_read_bridge u_bridge','cyclegan_ddr_read_bridge u_bridge')
    text=text.replace("16'he301","16'he311")
    text=text.replace('DDR + 200MHz encoder','DDR + 150MHz encoder')
    text=text.replace(' wire [31:0] cycles,mac_cycles,first_cycle;',' wire [31:0] cycles,mac_cycles,first_cycle,command_wait_cycles,data_wait_cycles,input_checksum;')
    text=text.replace('  .result_valid(),.result_ready(1\'b1),.result_stage(),.result_channel(),.result_x(),.result_y(),.result_data(),',
                      '  .command_wait_cycles(command_wait_cycles),.data_wait_cycles(data_wait_cycles),.input_checksum(input_checksum),')
    text=text.replace('.vio0_command(command),', '.vio0_command_wait_cycles(command_wait_cycles),.vio0_data_wait_cycles(data_wait_cycles),.vio0_input_checksum(input_checksum),\n  .vio0_command(command),')
    (dest/'cyclegan_encoder_board.v').write_text('// Derived from pe10_10/encoder/rtl/encoder_board.v; current compute unit.\n'+text,encoding='utf8')
    profile=json.loads((REF/'project/encoder_board/debug_profile.json').read_text())
    core=profile['debug_cores'][0];core['uuid']='e311a571b2ce4108af3e1b2833228701'
    # Inputs are listed first so host readback indices stay stable.
    probes=core['probes'];idx=next(i for i,p in enumerate(probes) if p['name']=='command')
    probes[idx:idx]=[dict(name='command_wait_cycles',width=32,init=None),dict(name='data_wait_cycles',width=32,init=None),dict(name='input_checksum',width=32,init=None)]
    (dest/'debug_profile.json').write_text(json.dumps(profile,indent=2))
    efx=Path(os.environ.get('EFINITY_HOME',r'D:\Efinity\2026.1'));sys.path.insert(0,str(efx/'debugger/bin'))
    from efx_dbg.define import DebugProfileBuilder
    from efx_dbg.rtl_gen import write_debug_top_verilog
    dp,_=DebugProfileBuilder.from_file(str(dest/'debug_profile.json'))
    write_debug_top_verilog(str(dest/'debug_top.v'),dp,'edb_top',True)
    ns='http://www.efinixinc.com/enf_proj';pn='http://www.efinixinc.com/peri_design_db'
    ET.register_namespace('efx',ns)
    tree=ET.parse(REF/'project/encoder_board/encoder_board.xml');p=tree.getroot();p.set('name','encoder_board')
    design=p.find(f'{{{ns}}}design_info')
    for e in list(design):
        if e.tag in (f'{{{ns}}}design_file',f'{{{ns}}}top_module'):design.remove(e)
    design.insert(0,ET.Element(f'{{{ns}}}top_module',name='cyclegan_encoder_board'))
    for idx,source in enumerate(SOURCES+['frame_pingpong.v','AXI4_AWARMux.v','cyclegan_encoder_board.v','DdrCtrl/DdrCtrl.v','debug_top.v']):
        design.insert(idx+1,ET.Element(f'{{{ns}}}design_file',name=source,version='default',library='default'))
    syn=p.find(f'{{{ns}}}synthesis')
    for e in list(syn):
        if e.get('name')=='include':syn.remove(e)
        elif e.get('name') in ('retiming','max_threads','mode'):
            e.set('value',{'retiming':'0','max_threads':'4','mode':'area'}[e.get('name')])
    for value in ('.','DdrCtrl'):ET.SubElement(syn,f'{{{ns}}}param',name='include',value=value,value_type='e_string')
    tree.write(dest/'encoder_board.xml',encoding='UTF-8',xml_declaration=True)
    pt=ET.parse(REF/'project/encoder_board/encoder_board.peri.xml')
    for clock in pt.findall(f'.//{{{pn}}}comp_output_clock'):
        if clock.get('name')=='clk_compute':clock.set('out_divider','16')
    pt.write(dest/'encoder_board.peri.xml',encoding='utf8',xml_declaration=True)
    shutil.copy2(REF/'project/encoder_board/encoder_board.sdc',dest/'encoder_board.sdc')
    sys.path.insert(0,str(efx/'pt/bin'))
    from api_service.design import DesignAPI
    api=DesignAPI();api.load(str(dest/'encoder_board.peri.xml'));api.generate(True,str(dest/'outflow'))
    if not (dest/'outflow/encoder_board.lpf').exists():raise RuntimeError('Interface generation failed')
    manifest={name:hashlib.sha256((ROOT/'rtl'/name).read_bytes()).hexdigest() for name in SOURCES}
    (dest/'source_manifest.json').write_text(json.dumps(dict(clock_hz=150000000,rtl_sha256=manifest),indent=2))
    print('STAGE1_BOARD_READY',dest)

if __name__=='__main__':
    cli=argparse.ArgumentParser();cli.add_argument('--assets',action='store_true');cli.add_argument('--board',type=Path)
    args=cli.parse_args()
    if args.assets:assets()
    if args.board:board(args.board)
