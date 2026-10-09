"""Make simulation-only initialization-compatible copies of legacy models.

always_comb evaluates at time zero. The legacy always @(*) shifter otherwise
leaves its uninitialized output X forever when its inputs remain constant zero.
No original vendor file or synthesis source is modified.
The mapped design also needs the LUT model to evaluate once at startup,
including feedback/control cones whose inputs initially stay constant.
"""
from pathlib import Path

root=Path(__file__).resolve().parent.parent
source=root/"yilisi_sim_models"/"efx_dsp48.v"
output=root/"build"/"sim"/"efx_dsp48_compat.sv"
output.parent.mkdir(parents=True,exist_ok=True)
text=source.read_text(encoding="utf8")
text=text.replace("always @(*)", "always_comb")
output.write_text(text,encoding="utf8")
lut_source=root/"yilisi_sim_models"/"efx_lut4.v"
lut_text=lut_source.read_text(encoding="utf8")
lut_text=lut_text.replace("   assign O = lut;", "   initial begin #0; lut = get_lut_value(3, {I3_net, I2_net, I1_net, I0_net}); end\n   assign O = lut;")
(output.parent/"efx_lut4_compat.sv").write_text(lut_text,encoding="utf8")
print("Prepared simulation-only DSP/LUT startup compatibility copies")
