# 验证记录

日期：2026-10-09。器件：Ti60F225，C4。工具：Efinity 2026.1.132、Icarus Verilog、Conda Python。

## 实际资源

包含 `mobilenet_bus_top` 的 32 bit 主机接口，不是单独 PE 的估算。综合使用 area 模式。

| 资源 | 实测 | 要求 | 结果 |
|---|---:|---:|---|
| EFX_LUT4 | 9148 | <10000 | 满足 |
| EFX_FF | 4761 | <8000 | 满足 |
| BRAM | 138 | <160，最多180 | 满足 |
| EFX_DSP48 | 100 | <160 | 满足 |
| EFX_ADD | 248 | 单独报告 | LUT4+ADD=9396 |

BRAM：cache 80 个 DPRAM10；参数 8 个 RAM10；DW halo 10 个 RAM10；DW 预排窗口 40 个 RAM10。FIFO 使用 512 bit 显式寄存器存储，不占 BRAM。

布局后的 LUT4 为 9150（5873 个独立 LUT4 + 3277 个 LUT4/FF 组合位置），FF 仍为 4761。248 个专用加法位置另计，两者合计 9398。布线额外占用 1481 个 XLR，器件总 XLR 使用量 12363；XLR 包含布线及独立 FF，不能当作 LUT4 数量。

原始记录：[综合报告](../build/efinity/outflow/mobilenet.map.rpt)、[模块资源分布](../build/efinity/outflow/mobilenet.res.csv)。

## 布局布线与时序

实际执行 `efx_run.bat mobilenet.xml --flow pnr`，结果 PASS。时钟约束为 10 ns / 100 MHz。

- 建立余量：+2.543 ns。
- 保持余量：+0.026 ns。
- 工具分析的最大时钟频率：134.102 MHz，仅作为此次核心布局的报告数值。

本工程没有实际板级 IO 分配，也没有主机总线 input/output delay 约束。该结果验证核心内部时序，不能直接用作板级接口或 FPGA 实测频率保证。没有生成或烧录板级 bitstream。

原始记录：[时序报告](../build/efinity/outflow/mobilenet.timing.rpt)、[布局报告及未分配端口](../build/efinity/outflow/mobilenet.place.rpt)、[布线报告](../build/efinity/outflow/mobilenet.route.rpt)。

## 功能验证

整数 golden model 使用独立 Python 计算，随机种子为 20261009。核心 RTL 测试通过 93 个场景、97 条指令、22787 个时钟。

覆盖 PW 1/2/7/32 通道及参数 RAM 跨 bank、NORM 全范围有符号参数、五种 DW 核、内部接缝/四边/四角、ZERO/REFLECT、有效宽高 1/2/3、量化截断/舍入/饱和、ReLU/ReLU6、最大池化、stride2 抽样、四象限保持、分段 PW 累加、四条指令排队、非法字段和地址、复位取消。

总线测试覆盖 PW 恒等映射、DW 3×3 九个非零 tap 与独立整数结果比较、参数地址自增、busy 时 backpressure、读结果快照、done W1C、复位清队列且保留之前完成的数据。

RTL 日志：[核心](../build/sim/unit.log)、[总线](../build/sim/bus.log)。综合网表总线测试同样通过上述 PW/DW 与总线检查：[网表仿真日志](../build/sim/postmap.log)。网表测试不包含延迟回标；建立/保持检查由上述 STA 完成。

主机工具的指令编码、象限打包与独立 golden 编码交叉核对通过，tile 打包/解包通过。

仿真兼容说明：原工程 DSP 模型的 `always @(*)` 在常量零输入下可能不执行初始组合计算，使 shifter 持续为 X。原 LUT 模型在映射后控制反馈网的启动阶段也存在漏求值现象。`sim/prepare_models.py` 只在 build 内生成副本：DSP 使用 `always_comb`，LUT 增加一次 `#0` 初始求值。真值表函数、X 传播和运算逻辑保持原样，原模型不修改，综合不使用行为模型。这些兼容修改不能替代板级验证。

## 周期与结构代价

从核心取出指令到测试平台观察完成，cache 和参数已载入，包含流水排空/写回。来自 [逐指令周期 CSV](../build/sim/commands.csv)。

| 典型指令 | 时钟周期 |
|---|---:|
| PW 1 通道，直接写回 | 13；开启舍入为14 |
| PW 32 通道，直接写回 | 44；开启舍入为45 |
| NORM | 14 |
| DW 1×2 / 2×1 | 314 |
| DW 2×2 | 340 |
| DW 3×3 | 405 |
| DW 7×7 | 925 |

DW 舍入通常增加 1 拍，最大池化增加 2 拍。当前 DW 采用预排窗口换取 LUT 节省，准备阶段约每 tap 12 拍，之后 PE 按每拍 100 个 MAC、一个 tap 输入运行；anchor 去重产生一个空拍。主机装载时间、cache 工作块调度与完整网络吞吐不在此表内。

## 复现

```powershell
./scripts/run_sim.ps1
./scripts/run_synthesis.ps1
./scripts/run_pnr.ps1
./scripts/run_postmap_sim.ps1
```

Efinity 在 ASCII TEMP 副本运行，结果复制到 build。软件架构、冻结 ISA、总线使用及范围见 [实现规格](implementation.md)。
