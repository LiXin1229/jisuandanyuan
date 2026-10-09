"""Create a reproducible synthesis project, without assigning board pins."""
from pathlib import Path
import xml.etree.ElementTree as ET
import argparse
import shutil

root=Path(__file__).resolve().parent.parent
parser=argparse.ArgumentParser()
parser.add_argument("--staging",type=Path)
parser.add_argument("--top",choices=["mobilenet_bus_top","cyclegan_bus_top","mn_instruction_fifo"],default="mobilenet_bus_top")
args=parser.parse_args()
destination=args.staging or root / "build" / "efinity"
destination.mkdir(parents=True,exist_ok=True)
ns="http://www.efinixinc.com/enf_proj"
ET.register_namespace("efx",ns)


def node(parent,tag,**attributes):
    return ET.SubElement(parent,"{"+ns+"}"+tag,attributes)


project=ET.Element("{"+ns+"}project",name="mobilenet",sw_version="2026.1.132")
device=node(project,"device_info")
node(device,"family",name="Titanium")
node(device,"device",name="Ti60F225")
node(device,"timing_model",name="C4")
design=node(project,"design_info",def_veri_version="sv_09",def_vhdl_version="vhdl_2008",unified_flow="false")
node(design,"top_module",name=args.top)
sources=["mn_cache.sv","mn_param_ram.sv","mn_instruction_fifo.sv","mn_dw_buffer.sv",
         "mn_pe_array.sv","mn_postprocess.sv","mn_model_rom.sv","mn_tanh.sv",
         "mobilenet_unit.sv","mobilenet_bus_top.sv","cyclegan_bus_top.sv"]
for source in sources:
    node(design,"design_file",name=("rtl/" if args.staging else "../../rtl/")+source,version="default",library="default")
if args.staging:
    (destination/"rtl").mkdir(exist_ok=True)
    for source in sources+["mn_isa.vh","mn_model_params_init.vh","mn_tanh_u8.mem"]:
        shutil.copy2(root/"rtl"/source,destination/"rtl"/source)
constraints=node(project,"constraint_info")
node(constraints,"sdc_file",name="mobilenet.sdc")
node(project,"sim_info")
node(project,"misc_info")
node(project,"ooc_info")
synthesis=node(project,"synthesis",tool_name="efx_map")
node(synthesis,"param",name="include",value="rtl" if args.staging else "../../rtl",value_type="e_string")
for name,value,kind in [
    ("work_dir","work_syn","e_string"),("write_efx_verilog","on","e_bool"),
    ("blackbox-error","1","e_option"),("hdl-loop-limit","20000","e_integer"),
    ("mode","area","e_option"),("dsp-input-regs-packing","1","e_option"),
    ("dsp-output-regs-packing","1","e_option"),("dsp-mac-packing","1","e_option"),
    ("bram_output_regs_packing","1","e_option"),("infer-clk-enable","3","e_option"),
    ("infer-sync-set-reset","1","e_option"),("retiming","0","e_option"),
    ("max_threads","4","e_integer")]:
    node(synthesis,"param",name=name,value=value,value_type=kind)
pnr=node(project,"place_and_route",tool_name="efx_pnr")
node(pnr,"param",name="work_dir",value="work_pnr",value_type="e_string")
node(pnr,"param",name="max_threads",value="4",value_type="e_integer")
ET.ElementTree(project).write(destination/"mobilenet.xml",encoding="utf-8",xml_declaration=True)
(destination/"mobilenet.sdc").write_text("create_clock -name clk -period 10.000 [get_ports clk]\n",encoding="ascii")
print(destination/"mobilenet.xml")
