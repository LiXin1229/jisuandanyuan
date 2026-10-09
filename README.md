# MobileNet 指令调度计算单元

目标：Ti60 F225 / Efinity 2026.1。数据为 signed Q4.4（8 bit），参数为 signed Q8.8（16 bit），tile 为 10×10。

已实现 PW 1～32 通道、逐通道 affine NORM、五种 DW 卷积核、零/不重复边界反射填充、ReLU/ReLU6、2×2 最大池化、真实 stride=2 的输出抽样、四象限写回、4 深指令 FIFO 和 32 bit 主机接口。

当前资源优先结构将 DW 窗口预排到 BRAM，随后逐拍送入 100 路 DSP。无跨指令流水。完整图像、特征图及参数由上层分块装入工作 cache。

- 顶层主机接口：`rtl/mobilenet_bus_top.sv`
- 计算核心：`rtl/mobilenet_unit.sv`
- 指令、接口、时序和限制：[实现说明](docs/implementation.md)
- 实测资源和验证：[验证记录](docs/validation_results.md)
- 原始架构讨论：[评估报告](docs/mobilenet_compute_unit_assessment.md)
- 主机指令/数据编码：`tools/mn_codec.py`

## 运行

在工程目录的 PowerShell 中：

```powershell
./scripts/run_sim.ps1
./scripts/run_synthesis.ps1
./scripts/run_pnr.ps1
./scripts/run_postmap_sim.ps1
```

默认 Python 为 `D:\Users\Administrator\anaconda3\python.exe`，Efinity 为 `D:\Efinity\2026.1`；脚本参数可覆盖。仿真使用 Icarus Verilog。综合源不包含器件行为模型。

Efinity 原生工具要求 ASCII 路径，因此综合脚本在 Windows TEMP 内建立隔离副本，报告复制回 `build/efinity/outflow`。可在 Efinity 打开生成的 `build/efinity/mobilenet.xml` 查看工程；从中文路径运行原生流程时仍建议使用提供的脚本。

这些脚本不会烧录 FPGA。工程尚未绑定实际板级总线引脚，也没有完整 MobileNet 网络权重和整网调度程序。
