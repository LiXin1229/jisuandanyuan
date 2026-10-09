# 计算单元 / CycleGAN epoch11

目标器件 Ti60 F225，Efinity 2026.1；100 路 DSP、10×10 tile、signed8 Q4.4 数据和 signed16 Q8.8 参数。

当前版本支持 `netG_B_epoch11.pth` 的 7×7 输出生成器，采用 checkpoint 的固定 BN 统计生成 affine 参数。整网调度在主机端运行，编码、残差、四相转置卷积和 Tanh 复用同一计算单元。核心及全部缓存/模型参数/Tanh 综合为 **187 BRAM、20077 LUT4、5239 FF、100 DSP**（当前 BRAM 预算约 200）；100MHz 内部时序通过布局布线检查。PW 无舍入执行时间为 `Cin+8` 拍；共享缓冲的 3×3 / 7×7 DW 分别连续发射 9 / 49 次 MAC，无填充执行时间为 30 / 66 拍。需要修补的边每个增加 3 拍，排队弹出间隔在执行时间基础上加 1 拍。

- [当前约 200 BRAM 预算下的统一 cache 优化](docs/bram_optimization_iteration7.md)
- [第六轮缓冲 CE 解耦、数据共享与 compact 优化](docs/buffer_optimization_iteration6.md)
- [第五轮整字 mux 可行性与综合对照](docs/mux_optimization_iteration5.md)
- [共享 3×3/7×7 缓冲、指令时间及第四轮资源优化](docs/executor_efficiency_iteration4.md)
- [第三轮一拍后处理与专用 3×3 快速路径](docs/executor_efficiency_iteration3.md)（历史版本）
- [第二轮执行器效率记录](docs/executor_efficiency_iteration2.md)（历史版本）
- [DSP48 乘加、移位与 ReLU 可行性核对](docs/dsp48_quantization_feasibility.md)
- [第一轮模型部署实现与验证范围](docs/cyclegan_iteration1.md)
- [v1 ISA、数据布局与总线基线](docs/implementation.md)（v2 差异见本轮记录）
- [开始实现前的可行性分析](docs/cyclegan_deployment_feasibility.md)
- [v1 验证记录](docs/validation_results.md)（历史版本）
- 固定模型顶层：`rtl/cyclegan_bus_top.sv`
- 可写参数顶层：`rtl/mobilenet_bus_top.sv`
- 主机调度与总线驱动：`tools/cyclegan_host.py`

所有空间核及部分 tile 共用 256 byte 寄存器缓冲，DW 窗口占用 **0 BRAM**，不再使用 cache scratch。三个逻辑 cache 统一映射到 160 个 2048×5 TDP BRAM，模型参数 25，Tanh 2。host/core 使用独立写端口，读取直接使用完整地址，删掉整字 bank 选择和第三 bank 写数据 mux；非法读用 BRAM 输出同步复位返回零。逻辑容量仍为 1536×800 bit，支持 20 bit 主机切片写掩码，可逐行写入并按 tile 读取。相比第四轮之前的专用 3×3 路径，统一空间窗口后完整 3×3 启动增加 13 拍；7×7 则从 765 拍降至 66～78 拍。此次 cache 修改不增加执行拍数，ISA 的原有 feature 地址上限保持兼容。

## 复现

在工程目录的 PowerShell 中执行。普通仿真/综合默认使用 PATH 中的 Python；模型工具需要 NumPy/Pillow，可用本机已提供的运行时：

```powershell
$modelPython='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $modelPython tools/prepare_cyclegan_assets.py
& $modelPython tools/cyclegan_host.py
& $modelPython tools/cyclegan_host.py --inverted
./scripts/run_sim.ps1 -Jobs 8
./scripts/run_synthesis.ps1 -Top cyclegan_bus_top
./scripts/run_pnr.ps1
./scripts/run_cyclegan_checks.ps1 -Python $modelPython
./scripts/run_cache_mapped.ps1
```

`prepare_cyclegan_assets.py` 只读取 `C:\Users\Administrator\Desktop\jisuan\pe10_10`，导出的整数参考保存在本工程 `build/cyclegan_model`。它会重建本工程的固定 ROM/Tanh 源文件。整网整数模型结果保存为 `build/cyclegan_schedule/output*.png` 和 `validation*.json`。

RTL 仿真使用 Icarus Verilog。综合脚本为 Efinity 建立 ASCII 路径副本，报告复制到 `build/efinity/outflow`。默认 `run_synthesis.ps1` 仍综合可写参数顶层；其综合网表测试用 `run_postmap_sim.ps1`。固定模型综合网表测试用 `run_cyclegan_checks.ps1`。

板上使用时，实现遵守 ready/rvalid 的 `write_word/read_word` 传输适配器，再将 `BusCore` 交给 `GeneratorScheduler`。目前没有实际板级传输适配器、DDR DMA 或自主 FPGA 网络控制器，脚本不会烧录 FPGA；整网验证为整数指令模型，未完成整帧 RTL 或板上验证。
