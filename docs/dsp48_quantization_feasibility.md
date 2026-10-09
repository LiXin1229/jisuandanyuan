# EFX_DSP48 乘加、移位和 ReLU 可行性核对

核对对象：Ti60、Efinity 2026.1，工程自带及工具安装目录的 `efx_dsp48.v`，以及 [Quantum Titanium Primitives User Guide v4.2](https://www.efinixinc.com/docs/efinity-quantum-ti-primitives-ug-v4.2.pdf) 的 DSP Block / EFX_DSP48 章节。另参阅 [官方 DSP 架构说明](https://www.efinixinc.com/blog/blog-2026-dsp.html)。

结论：DSP 内部乘加和输出右移可用；“C 任意位段同时独立表示加数与移位量”“OP 内部实现零逻辑 ReLU”“移位等于完整 int8 量化”不能成立。当前工程的固定右移 8 位已经是接线，不存在外部桶形移位器，也不是原来 25 拍后处理的原因。

## 1. 正确的数据路径和 C 端口时序

NORMAL 模式是 19×18 乘法、48 bit 加减/累加，`W` 位于输出移位之前，`O` 位于移位之后。有符号模式输出右移为算术右移；使用加法器及输出移位时需要 W_REG=1、O_REG=1。

NORMAL 的移位值来自 C[3:0]，在时钟上升沿且 SHIFT_ENA 有效时装入内部 S 寄存器。C_REG 是加法器侧的独立流水配置；不能假设它会同时延迟移位控制。工程模型见 `yilisi_sim_models/efx_dsp48.v` 的 shift_val、W_pipe、O_pipe。

若 N_SEL=C 且同拍装载 S，C 的低四位确实同时参加加法；它们不是从加数中“挖掉”或独立保留的字段。冲突的条件是 `c[3:0] != shift`，与 c 是否大于 15 无关。例如 a*b=1000、c=20、期望右移 8：

- 原样 C=20，低四位为 4，实际结果 `(1000+20)>>4 = 63`。
- 强行把低四位换成 8，C 变成 24，实际结果 `(1000+24)>>8 = 4`。
- 正确结果 `(1000+20)>>8 = 3`。

可以在无效/初始化周期送 C=8、SHIFT_ENA=1 装载 S；后续 SHIFT_ENA=0，C=20，得到正确结果 3。需要明确清零/复位对 S 的影响，以及乘法、C、OP、有效信号的流水对齐。这个方案支持任意合法 C 加数，不要求 c 的低四位等于移位量。

## 2. ReLU 和饱和仍需外部逻辑

整数 OP 00/01/10/11 分别执行 M+N、M-N、-M+N、-M-N-1。没有按符号选择零或结果的模式。OVFL 报告 DSP 加法器位宽的溢出，不表示结果为负，也不是 int8 越界标志。

实测 M=-50、N=0 时，四种 OP 的结果为 -50、-50、50、49，均不会产生 ReLU 所需的零；10000 也不会被硬件自动钳到 int8 的 127。`sign ? 0 : data` 可以组合实现而无需额外输出寄存器，但仍需要按数据位宽付出逻辑成本；不能把一个输出位的 LUT 成本当作 100 路 8 bit 输出的总成本。

当前量化是 `sat8((S+round_bias)>>8)`，还可能执行 ReLU6、无效像素置零、2×2 最大池化。内置移位不会代替这些功能。ROUNDING 参数用于 BFLOAT，不应作为整数右移舍入开关使用。

## 3. 当前阵列怎样使用才保持数值正确

当前 `mn_pe_array` 使用 M_SEL=P、N_SEL=W、W_SEL=X：

```text
W_next = W + pixel * weight
O      = W >>> shift
```

反馈必须继续使用移位前的 W。改成 O 反馈会把量化后的数值送回累加环路，并引入 O 寄存器的反馈延迟，改变 PW/普通卷积结果。

该结构中 C 不作为加数，可以专门装载输出移位值，不存在加数冲突。但当前 post 从原始和中固定取 bits15:8，本来就不消耗移位 LUT；将它换成 O 的内置右移不能据此承诺资源或周期收益。真正可以缩短的是后处理扫描、流水寄存和空状态。

若启用动态输出移位，普通 Q4.4 输出用 8，末层 Tanh 必须继续得到原始和，即使用 0 并按参考的 `(S+8)>>4` 形成 LUT 索引。不能先右移 8 再送 Tanh。保持 W 原始累加还能支持 raw continuation；不应每段移位后再累加。

## 4. a*b+c 与固定 NORM

N_SEL=C 可以实现一个普通的乘加，但它是实例参数，不能通过 OP 在每条指令之间切换成 N_SEL=W。因此，直接把当前共享阵列改成 N_SEL=C 会丢失原有内部累加路径。

当前 NORM 实际为 `x_raw*a_raw + 16*b_raw + rounding128`。epoch11 的全部固定 b_raw 范围实测为 -722～490，所以带舍入的 C 值范围 -11424～7968，可以装入 signed18。但通用可写参数允许全部 signed16 b_raw，此时 16*b_raw 需要 signed20，最大正值加舍入后甚至需要 signed21，不能无条件塞进 signed18 C。当前通过先算 16*b、再算 x*a，使用同一 DSP 的 W 累加，完整保留参数范围。

为固定模型单独增加 N_SEL=C 的 NORM 数据通路可以研究，但需计入额外 DSP、数据选路和阶段控制；收益不能只按少掉一拍乘加估算。若融合 PW/NORM，也必须保留参考中的中间 int8 舍入和饱和，不能直接把两个仿射表达式折叠后假设逐值等价。

## 5. 其他需要修正的规格描述

- 11×10 和 8×8 属于 DUAL 模式，NORMAL 并不因输入数值较小而自动改变移位字段。
- QUAD 是一个 7×6 和三个 4×4；7×6 的结果会截到 12 bit。移位字段依次为 C[15:12]、[11:8]、[7:4]、[3:0]。
- 即使固定移位超过 15，常量位选和符号扩展也可以直接接线；只有需要在多个移位量之间动态选择时才需评估外部移位选路。

## 6. 已执行的原语测试

`sim/tb_dsp_quant_probe.sv` 使用工程的供应商兼容仿真模型，验证 C 字段冲突、预装载移位寄存器、四个 OP 的实际结果、无 int8 自动饱和、W 原始累加与 O 移位输出独立。得到 raw W=512、shift=8 时 O=2；保持 W、改 shift=0 后 O=512。这个测试验证数值行为，不是布局布线或最大频率测试。

复现：

```powershell
python sim/prepare_models.py
iverilog -g2012 -s tb_dsp_quant_probe -o build/sim/dsp_quant_probe.vvp sim/tb_dsp_quant_probe.sv build/sim/efx_dsp48_compat.sv
vvp -i build/sim/dsp_quant_probe.vvp
```

本轮没有根据“零 LUT ReLU”假设修改生产 PE。已完成的执行器效率优化针对扫描、装载与状态机开销，资源和时序见 [第二轮效率记录](executor_efficiency_iteration2.md)。
