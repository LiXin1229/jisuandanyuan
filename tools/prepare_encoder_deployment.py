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
           'cyclegan_rgb_loader.sv','cyclegan_encoder.sv','cyclegan_ddr_read_bridge.sv',
           'mn_instance_norm.sv','mn_instance_norm_coeff.sv','mn_instance_norm_gamma.sv',
           'cyclegan_residual_instance_scheduler.sv',
           'ip/norm_sqrt80/norm_sqrt80.v','ip/norm_div64_40/norm_div64_40.sv']

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

def board(dest,residual=False,decoder=False,output=False):
    dest=dest.resolve();dest.mkdir(parents=True,exist_ok=True)
    sources=SOURCES+(['mn_residual_rom.sv','cyclegan_residual_scheduler.sv'] if residual else [])
    if decoder:sources+=['mn_decoder_rom.sv','cyclegan_decoder_scheduler.sv','cyclegan_feature_writer.sv','cyclegan_write_arbiter.sv']
    if output:
        assert decoder and residual
        sources+=['mn_generator_rom.sv']
    for name in sources+['mn_isa.vh','mn_model_params_init.vh','mn_tanh_u8.mem']:
        (dest/name).parent.mkdir(parents=True,exist_ok=True)
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
    if residual:
        text=text.replace("16'he311","16'he312")
        # Stage-2 board profile: retain calibration, then use the verified
        # sampling phase. Command 5 bit3 permits same-bitstream phase A/B tests.
        text=text.replace(' wire enable=cal_done && cal_pass;',
            ' wire [2:0] auto_shift;wire auto_shift_ena;\n'
            ' reg [2:0] phase_value=6;reg phase_applied=0,phase_change=0;\n'
            ' assign shift=cal_done ? phase_value : auto_shift;\n'
            ' assign shift_ena=auto_shift_ena || (cal_done && !phase_applied) || phase_change;\n'
            ' wire enable=cal_done && cal_pass && phase_applied;')
        text=text.replace('.shift(shift),.shift_sel(),.shift_ena(shift_ena),', '.shift(auto_shift),.shift_sel(),.shift_ena(auto_shift_ena),')
        text=text.replace('  begin_frame<=0;acquire<=0;release_frame<=0;',
            '  begin_frame<=0;acquire<=0;release_frame<=0;phase_change<=0;phase_applied<=cal_done;')
        text=text.replace('   ack<=0;', '   phase_value<=6;phase_applied<=0;\n   ack<=0;')
        text=text.replace('5:begin protocol_error<=0;',
            '5:begin if(command[3]) begin phase_value<=command[2:0];phase_change<=1;end protocol_error<=0;')
        text=text.replace('.vio0_calibration({22\'d0,cal_shift,cal_log})',
            '.vio0_calibration({18\'d0,phase_applied,phase_value,cal_shift,cal_log})')
        text=text.replace('cyclegan_encoder u_core','cyclegan_encoder #(.RESIDUAL_ENABLE(1)) u_core')
        text=text.replace(' reg run_toggle=0,debug_toggle=0,debug_ddr=0;',
            ' reg run_toggle=0,debug_toggle=0,debug_ddr=0,resume_toggle=0,pause_mode=0;\n'
            ' reg resume_s1=0,resume_s2=0,resume_seen=0,core_resume=0,paused_s1=0,paused_s2=0;\n'
            ' wire paused;wire [3:0] blocks_completed;wire [10:0] residual_output_base;\n'
            ' wire [31:0] encoder_cycles,residual_cycles,block_cycles;')
        text=text.replace('  .raw_rows(),',
            '  .pause_each_block(pause_mode),.resume(core_resume),.paused(paused),.blocks_completed(blocks_completed),\n'
            '  .residual_output_base(residual_output_base),.encoder_cycles(encoder_cycles),\n'
            '  .residual_cycles(residual_cycles),.block_cycles(block_cycles),\n  .raw_rows(),')
        text=text.replace('  core_start<=0;core_dbg_rd<=0;', '  core_start<=0;core_dbg_rd<=0;core_resume<=0;')
        text=text.replace('   run_s1<=0;', '   resume_s1<=0;resume_s2<=0;resume_seen<=0;\n   run_s1<=0;')
        text=text.replace('   run_s1<=run_toggle;',
            '   resume_s1<=resume_toggle;resume_s2<=resume_s1;\n'
            '   if(resume_s2!=resume_seen) begin resume_seen<=resume_s2;core_resume<=1;end\n   run_s1<=run_toggle;')
        text=text.replace('   ack<=0;', '   paused_s1<=0;paused_s2<=0;resume_toggle<=0;pause_mode<=0;\n   ack<=0;')
        text=text.replace('   done_s1<=complete_toggle;', '   paused_s1<=paused;paused_s2<=paused_s1;\n   done_s1<=complete_toggle;')
        text=text.replace('3:if(!running && (slots[1:0]==2 || slots[3:2]==2)) acquire<=1;',
            '3:if(!running && (slots[1:0]==2 || slots[3:2]==2)) begin acquire<=1;pause_mode<=command[0];end')
        text=text.replace('4,6:if(!running)', '4,6:if(!running || (command[30:28]==4 && paused_s2))')
        text=text.replace('     default:begin protocol_error',
            '     7:begin if(running && paused_s2) resume_toggle<=~resume_toggle;else protocol_error<=1;ack<=command[31];pending<=0;end\n'
            '     default:begin protocol_error')
        text=text.replace('  .vio0_command(command),',
            '  .vio0_residual_status({16\'d0,residual_output_base,blocks_completed,paused_s2}),\n'
            '  .vio0_encoder_cycles(encoder_cycles),.vio0_residual_cycles(residual_cycles),.vio0_block_cycles(block_cycles),\n'
            '  .vio0_command(command),')
        for fragment in ('7:begin if(running && paused_s2)', '.resume(core_resume)',
                         'phase_change<=1;', '.RESIDUAL_ENABLE(1)', '.vio0_residual_status('):
            assert text.count(fragment)==1,('Board template expansion failed',fragment)
        # Reuse the existing 800-bit acknowledged mailbox for diagnostics.
        # Separate VIO statistics probes cost three synchronizer FFs and a
        # scan register per bit. Snapshot only while idle or block-paused;
        # all source counters and the held command bus are then stable.
        text=text.replace("16'he312","16'he313")
        text=text.replace("{21'd0,command[10:0]}","{command[27],20'd0,command[10:0]}")
        text=text.replace('if(debug_ddr) debug_state<=3;else begin',
            'if(debug_ddr) debug_state<=3;else if(debug_address[31]) debug_state<=5;else begin')
        text=text.replace('    3:if(bridge_req_ready)',
            # A statistics reply defines only its low 32 bits. Keeping the
            # other 768 bits avoids a third input on the full data mux.
            "    5:begin read_hold[31:0]<=statistic_word;debug_complete<=~debug_complete;debug_state<=0;end\n"
            '    3:if(bridge_req_ready)')
        # read_hold stays stable until the next acknowledged read. VIO already
        # synchronizes every input bit in clk_sys; the completion toggle has
        # also crossed two stages before ack. A second 800-bit data bank is
        # therefore redundant. The host reads only after receiving that ack.
        text=text.replace('reg [799:0] read_hold=0,read_data=0;',
            'reg [799:0] read_hold=0;wire [799:0] read_data=read_hold;')
        text=text.replace('read_data<=0;', '').replace('read_data<=read_hold;', '')
        text=text.replace(' wire [31:0] status=',
            " reg [31:0] statistic_word;\n always @* begin\n  case(debug_address[3:0])\n"
            "   0:statistic_word=cycles;1:statistic_word=mac_cycles;2:statistic_word=first_cycle;\n"
            "   3:statistic_word={frames,chunks};4:statistic_word=read_id;\n"
            "   5:statistic_word={18'd0,phase_applied,phase_value,cal_shift,cal_log};\n"
            "   6:statistic_word=command_wait_cycles;7:statistic_word=data_wait_cycles;8:statistic_word=input_checksum;\n"
            "   9:statistic_word={16'd0,residual_output_base,blocks_completed,paused_s2};\n"
            "   10:statistic_word=encoder_cycles;11:statistic_word=residual_cycles;12:statistic_word=block_cycles;\n"
            "   default:statistic_word=0;\n  endcase\n end\n wire [31:0] status=")
        text=text.replace("slots,push_ready,3'd0}","slots,push_ready,paused_s2,2'd0}")
        # Preserve status and all 800 readback bits, plus the upload outputs.
        import re
        text=re.sub(r'\.vio0_(?:cycles|mac_cycles|first_cycle|counts|frame_id|calibration|command_wait_cycles|data_wait_cycles|input_checksum|residual_status|encoder_cycles|residual_cycles|block_cycles)\([^\n]*?\),(?=\.vio0_|\n|\s)', '',text)
        # Concatenation arguments contain commas but no parentheses; the
        # non-greedy match above stops at each complete port expression.
        assert '.vio0_cycles(' not in text and '.vio0_block_cycles(' not in text
        for fragment in ('read_hold[31:0]<=statistic_word;', 'debug_address[31]', 'paused_s2,2\'d0}', 'read_data=read_hold;'):
            assert text.count(fragment)==1,('Compact mailbox expansion failed',fragment)
    if decoder:
        assert residual
        text=text.replace("16'he313","16'he314").replace('.RESIDUAL_ENABLE(1)', '.RESIDUAL_ENABLE(1),.DECODER_ENABLE(1)')
        text=text.replace("(command[30:28]==4 && paused_s2)","paused_s2")
        text=text.replace(' wire [31:0] encoder_cycles,residual_cycles,block_cycles;',
            ' wire [31:0] encoder_cycles,residual_cycles,block_cycles,decoder_cycles,layer_cycles;wire [1:0] layers_completed;\n'
            ' wire feature_write_valid,feature_write_ready,writer_fault;wire [31:0] feature_write_addr;wire [399:0] feature_write_data;')
        text=text.replace('  .residual_cycles(residual_cycles),.block_cycles(block_cycles),',
            '  .residual_cycles(residual_cycles),.block_cycles(block_cycles),\n'
            '  .decoder_cycles(decoder_cycles),.layer_cycles(layer_cycles),.layers_completed(layers_completed),\n'
            '  .feature_write_valid(feature_write_valid),.feature_write_ready(feature_write_ready),.feature_write_addr(feature_write_addr),.feature_write_data(feature_write_data),')
        text=text.replace('   default:statistic_word=0;',
            "   13:statistic_word={30'd0,layers_completed};14:statistic_word=decoder_cycles;15:statistic_word=layer_cycles;\n   default:statistic_word=0;")
        # Frame upload and feature writer share a transaction-owned AXI port.
        start=text.index(' frame_pingpong u_pp(');end=text.index(' reg run_toggle=',start)
        pp=text[start:end]
        for name in ('awvalid','awready','awaddr','awlen','wvalid','wready','wdata','wlast','bvalid','bready'):
            pp=pp.replace(f'.{name}({name})',f'.{name}(pp_{name})')
        wires=' wire pp_awvalid,pp_awready,pp_wvalid,pp_wready,pp_wlast,pp_bvalid,pp_bready;wire [31:0] pp_awaddr;wire [7:0] pp_awlen;wire [127:0] pp_wdata;\n'
        wires+=' wire fw_awvalid,fw_awready,fw_wvalid,fw_wready,fw_wlast,fw_bvalid,fw_bready;wire [31:0] fw_awaddr;wire [7:0] fw_awlen;wire [127:0] fw_wdata;\n'
        writer=' cyclegan_feature_writer u_writer(.cclk(clk_compute),.crstn(crstn),.s_valid(feature_write_valid),.s_ready(feature_write_ready),.s_addr(feature_write_addr),.s_data(feature_write_data),.fault(writer_fault),\n'
        writer+='  .dclk(clk_sys),.drstn(drstn),.enable(enable),'+','.join(f'.{n}(fw_{n})' for n in ('awvalid','awready','awaddr','awlen','wvalid','wready','wdata','wlast','bvalid','bready'))+',.bresp(bresp));\n'
        arb=' cyclegan_write_arbiter u_write_arbiter(.clk(clk_sys),.rstn(drstn),\n'
        arb+='  '+','.join(f'.a_{n}(pp_{n})' for n in ('awvalid','awready','awaddr','awlen','wvalid','wready','wdata','wlast','bvalid','bready'))+',\n'
        arb+='  '+','.join(f'.b_{n}(fw_{n})' for n in ('awvalid','awready','awaddr','awlen','wvalid','wready','wdata','wlast','bvalid','bready'))+',\n'
        arb+='  '+','.join(f'.{n}({n})' for n in ('awvalid','awready','awaddr','awlen','wvalid','wready','wdata','wlast','bvalid','bready'))+');\n'
        text=text[:start]+wires+pp+writer+arb+text[end:]
        text=text.replace('bridge_fault,core_fault,running,ack','bridge_fault,(core_fault|writer_fault),running,ack')
        for fragment in ('u_writer(', 'u_write_arbiter(', '.feature_write_data(feature_write_data)', '13:statistic_word='):
            assert text.count(fragment)==1,fragment
    if output:
        text=text.replace("16'he314","16'he315").replace('.DECODER_ENABLE(1)', '.DECODER_ENABLE(1),.OUTPUT_ENABLE(1)')
        text=text.replace('wire [1:0] layers_completed;', 'wire [1:0] layers_completed;wire output_completed;wire [31:0] output_cycles;')
        text=text.replace('.decoder_cycles(decoder_cycles),', '.output_completed(output_completed),.output_cycles(output_cycles),.decoder_cycles(decoder_cycles),')
        text=text.replace('case(debug_address[3:0])','case(debug_address[4:0])')
        text=text.replace('   default:statistic_word=0;', "   16:statistic_word=output_cycles;17:statistic_word={31'd0,output_completed};\n   default:statistic_word=0;")
        for fragment in ('.OUTPUT_ENABLE(1)', '.output_cycles(output_cycles)', '16:statistic_word=output_cycles;'):
            assert text.count(fragment)==1,fragment
    (dest/'cyclegan_encoder_board.v').write_text('// Derived from pe10_10/encoder/rtl/encoder_board.v; current compute unit.\n'+text,encoding='utf8')
    profile=json.loads((REF/'project/encoder_board/debug_profile.json').read_text())
    core=profile['debug_cores'][0];core['uuid']=('e315' if output else 'e314' if decoder else 'e313' if residual else 'e311')+'a571b2ce4108af3e1b2833228701'
    # Inputs are listed first so host readback indices stay stable.
    probes=core['probes'];idx=next(i for i,p in enumerate(probes) if p['name']=='command')
    probes[idx:idx]=[dict(name='command_wait_cycles',width=32,init=None),dict(name='data_wait_cycles',width=32,init=None),dict(name='input_checksum',width=32,init=None)]
    if residual:
        idx=next(i for i,p in enumerate(probes) if p['name']=='command')
        probes[idx:idx]=[dict(name=name,width=32,init=None) for name in ('residual_status','encoder_cycles','residual_cycles','block_cycles')]
        probes[:]=[p for p in probes if p['name'] in ('status','read_data0','read_data1','read_data2','read_data3','command','payload0','payload1')]
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
    for idx,source in enumerate(sources+['frame_pingpong.v','AXI4_AWARMux.v','cyclegan_encoder_board.v','DdrCtrl/DdrCtrl.v','debug_top.v']):
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
    manifest={name:hashlib.sha256((ROOT/'rtl'/name).read_bytes()).hexdigest() for name in sources}
    (dest/'source_manifest.json').write_text(json.dumps(dict(clock_hz=150000000,rtl_sha256=manifest),indent=2))
    print('STAGE1_BOARD_READY',dest)

if __name__=='__main__':
    cli=argparse.ArgumentParser();cli.add_argument('--assets',action='store_true');cli.add_argument('--board',type=Path)
    args=cli.parse_args()
    if args.assets:assets()
    if args.board:board(args.board)
