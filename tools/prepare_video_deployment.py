"""Build the current compute core with the imported SC2210/ISP/HDMI shell."""
from pathlib import Path
import argparse,hashlib,json,os,shutil,sys
import xml.etree.ElementTree as ET
import prepare_encoder_deployment as base
ROOT=base.ROOT

def prepare(dest):
 dest=dest.resolve();base.board(dest,residual=True,decoder=True,output=True)
 manifest=json.loads((dest/'source_manifest.json').read_text())
 video=sorted((ROOT/'rtl/video').glob('*.v'))+sorted((ROOT/'rtl/video').glob('*.sv'))
 for source in video:
  shutil.copy2(source,dest/source.name)
  manifest['rtl_sha256']['video/'+source.name]=hashlib.sha256(source.read_bytes()).hexdigest()
 shutil.copy2(ROOT/'rtl/video/camera_gamma.mem',dest/'camera_gamma.mem')
 manifest['rtl_sha256']['video/camera_gamma.mem']=hashlib.sha256((dest/'camera_gamma.mem').read_bytes()).hexdigest()
 manifest['board_sha256']={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (ROOT/'board/video').iterdir() if p.is_file()}
 manifest['video_contract']={'sensor':'SC2210 1920x1080 four-lane RAW12','roi':[640,300,640,480],
  'isp':['BGGR bilinear demosaic','AWB','gamma','2x2 RGB max pool'],'network_input':[320,240],
  'hdmi':[1280,720,60],'display_scale':2,'compute_mhz':2400/14,'ddr_ui_mhz':96,
  'schedule':'overlap encoder with VSYNC acknowledgement and original copy; gate final writes until bank ready',
  'styled_bases':[0x600000,0x700000],
  'original_bases':[0x800000,0x900000],'tile_layout':'50 valid + 14 zero + 50 valid + 14 zero'}
 ns='http://www.efinixinc.com/enf_proj';ET.register_namespace('efx',ns);n={'e':ns}
 tree=ET.parse(dest/'encoder_board.xml');project=tree.getroot();design=project.find('e:design_info',n)
 design.find('e:top_module',n).set('name','cyclegan_camera_board')
 for e in list(design):
  if e.tag.endswith('design_file') and e.get('name') in ('frame_pingpong.v','AXI4_AWARMux.v','cyclegan_encoder_board.v'):design.remove(e)
 for source in video:design.insert(1,ET.Element('{'+ns+'}design_file',name=source.name,version='default',library='default'))
 profile=json.loads((ROOT/'board/video/debug_profile.json').read_text())
 (dest/'debug_profile.json').write_text(json.dumps(profile,indent=2)+'\n')
 efx=Path(os.environ.get('EFINITY_HOME',r'D:/Efinity/2026.1'))
 sys.path.insert(0,str(efx/'debugger/bin'))
 from efx_dbg.define import DebugProfileBuilder
 from efx_dbg.rtl_gen import write_debug_top_verilog
 dp,_=DebugProfileBuilder.from_file(str(dest/'debug_profile.json'));write_debug_top_verilog(str(dest/'debug_top.v'),dp,'edb_top',True)
 pn='http://www.efinixinc.com/peri_design_db';pt=ET.parse(ROOT/'board/video/camera_board.peri.xml');pt.getroot().set('name','encoder_board')
 for c in pt.findall('.//{'+pn+'}comp_output_clock'):
  if c.get('name')=='clk_compute':c.set('out_divider','14')
 pt.write(dest/'encoder_board.peri.xml',encoding='UTF-8',xml_declaration=True)
 (dest/'encoder_board.sdc').write_text((ROOT/'board/video/camera_board.sdc').read_text().replace('camera_board.pt.sdc','encoder_board.pt.sdc'))
 sys.path.insert(0,str(efx/'pt/bin'));from api_service.design import DesignAPI
 api=DesignAPI();api.load(str(dest/'encoder_board.peri.xml'));api.generate(True,str(dest/'outflow'))
 tree.write(dest/'encoder_board.xml',encoding='UTF-8',xml_declaration=True)
 assert (dest/'outflow/encoder_board.lpf').exists()
 (dest/'source_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
 print('VIDEO_BOARD_READY',dest,flush=True)

if __name__=='__main__':
 ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--board',required=True,type=Path)
 prepare(ap.parse_args().board)
