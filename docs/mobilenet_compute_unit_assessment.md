# MobileNet 指令调度计算单元评估

评估日期：2026-10-09。目标芯片：Ti60 F225。工程目录：`C:/Users/Administrator/Desktop/计算单元`。

本文件保留实现前的评估推导。最终 RTL 已采用 BRAM 预排 DW 窗口与显式寄存器 FIFO，实际资源、周期和验证结果以 [实现规格](implementation.md) 和 [验证记录](validation_results.md) 为准。

## 1. 结论和评估范围

100 个空间位置并行、通道和卷积核 tap 按时钟串行，是适合本任务的结构。PW 和 DW 可以共用 100 个 NORMAL 模式 DSP48。DSP 与 BRAM 目标有较大实现空间；逻辑 FF 小于 8000 可通过紧凑邻域缓存实现；LUT4 小于 10000 是主要风险，不能在完整 RTL 综合前承诺。

建议采用：800×1024 片内工作 cache、100×8 输入寄存器、2×16 参数寄存器、100 个 DSP 内部累加器、16×16×8 DW halo、100 路定点输出/激活、25 路两级最大池化、四象限独立写使能、4×128 指令 FIFO。

用户已确认参数缓冲区是 2×16 bit、cache 是 800 bit×1024 深度、芯片是 Ti60 F225；反射 1/3 是填充宽度。定点格式按**含符号的总宽度**解释：数据 signed 8 bit、4 个小数位；参数 signed 16 bit、8 个小数位。默认卷积 stride=1、dilation=1，另讨论 stride=2 的扩展。

本次是架构评估，未修改生产 RTL，未实现完整计算单元，也没有整机综合或布局布线结果。资源区间是结构估算和设计预算。

## 2. 已有工程

| 文件或目录 | 内容与现状 |
|---|---|
| `conv_mem/mem/mem_800_512.v` | 800 bit×512 cache，40 个 512×20 BRAM 并联；每片写掩码；9 bit 地址 |
| `conv_mem/conv_mem_unit/bram_10kb.v` | Titanium Simple Dual Port RAM 封装，512×20，读输出寄存器关闭 |
| `conv_mem/conv_mem_unit/efx_ram10.v` | EFX_RAM10 仿真模型；地址锁存使能和真正写使能分离 |
| `ip/bram_10kb` | 同规格生成 IP、示例工程和 BRAM IP 测试平台 |
| `yilisi_sim_models` | DSP48、DSP24、DSP12、LUT、FF 等模型；不是已有 PE RTL |

未发现计算单元顶层、PE 阵列、DW 拼接、量化/激活、池化、指令译码或完整系统验证平台。`Ti60F225_devkit/bram_ed.xml` 是 BRAM 示例工程，不是计算单元工程。

现有 `we_a[i] & waddren` 必须保留：仅拉低 `waddren` 会保持旧地址，不能代替写使能。`rdata_valid` 对应当前关闭输出寄存器的读配置；将来打开 BRAM 输出寄存器后须同步增加 valid 延迟。

端口 `wdata_a[0:39]` / `rdata_b[0:39]` 是 unpacked array，应明确按 SystemVerilog 编译。编译文件表不能同时包含多个副本的 `bram_10kb` 或 `EFX_RAM10`。

## 3. 图像容量和分块调度

一张图的 tile 网格为 32×24；每个 RGB 通道各有 768 个 tile，总计 2304 个 800 bit tile：

```text
单通道 tile：10×10×8 = 800 bit = 100 byte
RGB 图像：32×24×3 = 2304 tile = 230400 byte
目标 cache：1024 tile = 102400 byte = 100 KiB
```

因此“已经载入 cache”的前提只能指**当前工作块**，不能指完整输入图像。完整 RGB 的原始位数在理想零浪费情况下就需 180 个 10 Kbit BRAM，已占满允许的最高值；固定 800 bit 宽的实际存储还会产生深度粒度浪费。更高通道特征图及全模型参数同样需要分块加载。

单个输入图像行 tile 长是逻辑图像信息，不应直接当作局部 cache 的地址步长。完整 32 通道特征图一行就占 32×32=1024 个 tile，DW 若保存三行至少需 3072 个地址。

建议明确区分：

- 逻辑 feature-map 尺寸、tile 位置：用于 padding 和输出形状。
- cache 局部 `tile_pitch`、`row_pitch`：用于当前已加载矩形工作块的物理寻址。
- 当前通道数/通道组宽度 `Cstore`：决定相邻空间 tile 的间隔。

例如把 3 行×6 列×32 通道加载到局部矩形，占 576 个地址；中间 1 行×4 列×32 通道输出占 128 个地址，合计 704，剩余空间可放其他工作数据。这里局部 row_pitch=192，而原始图像每行 32 个 tile。外部加载、回写和参数加载需要上层调度接口；外存控制器资源未计入本报告的计算核心预算。

## 4. Cache 布局和四象限写入

推荐 tile-major、channel-minor：同一空间位置的通道连续，PW 逐拍读取；每个 800 bit tile 内按 TL、TR、BL、BR 四个 5×5 象限排列，每象限 200 bit。

现有 800×512 使用 40 个 512×20 BRAM。目标 800×1024 有两条实现路径：

1. 直接采用 80 个 1024×10 BRAM。每象限 20 个 BRAM；优先考虑这个结构，避免上下深度 bank 的宽读 mux。
2. 两个现有 800×512 深度 bank，合计 80 个 BRAM；高位地址选择 bank，读路由需 800 bit 选择及 bank-valid 对齐。

不能只将地址从 9 bit 改成 10 bit而保留现有 512 深 IP 配置。80 BRAM 是该 800×1024 宽总线组织的精确基础用量；BRAM 位宽选项可由官方资料和本地 EFX_RAM10 模型交叉核对。

象限写入掩码：

| 写模式 | 目标 1024 深 cache 的使能分组 |
|---|---|
| FULL | 80 片全部写 |
| TL | 片 0–19 |
| TR | 片 20–39 |
| BL | 片 40–59 |
| BR | 片 60–79 |

该编号是**新定义的象限存储映射**。现有模块只有 40 片的掩码能力，注释提到“平面”；没有足够上层代码证明已有外部数据已经采用此象限布局。

池化产生 25 个 8 bit 值，即 200 bit。四个相邻输入空间 tile 的池化结果合并到一个输出 tile；它们必须属于同一个输出通道。池化结果可用固定接线复制到四个 200 bit 象限位置，再只使能目标象限，不必实现 800 bit 动态 barrel shifter，也不需要 read-modify-write。

只写一个象限不表示整个输出 tile 完成。需按写入覆盖率管理完成状态，或由调度器保证消费者仅在必要象限完成后启动。部分有效边缘 tile 还需有效宽高/象限信息，避免读到旧内容。

## 5. 定点计算规范

```text
x_real = x_raw / 16
w_real = w_raw / 256
p_raw = x_raw * w_raw        # 小数位数为 12
S_raw = sum(p_raw)
y_raw = saturate_signed8(round(S_raw / 256))
```

8×16 乘积用 24 bit 表示。保守累加位宽：PW32 为 29 bit，DW7×7 为 30 bit；统一 32 bit 的数学结果范围足够支持题设两个基础模式，DSP 内部实际使用 48 bit。不得每次 MAC 后量化或饱和，也不要把 partial sum 当 Q4.4 写回普通 cache。

若扩展到 32 通道×49 tap 的普通卷积，应按 35 bit 的保守累加位宽设计，或直接保留 DSP48 输出；32 bit 不再保证安全。

建议第一版固定量化右移 8 位。需要舍入时可定义 `floor((S_raw+128)/256)`，即最近值、平局向正方向；最终 Python 和 RTL 必须使用同一规则。避免以“负数也加同一偏移不对”为理由擅自改变舍入规则，也不能直接截取 8 bit而省略饱和。

为了省 LUT，可把 +128 放入 DSP 累加初值，最终直接移位。无偏置时增加一次常数预置 MAC；norm 时可用 `16*(sign_extend(b_raw)+8)` 同时预置偏置和舍入量。`b_raw+8` 在广播侧按 18 bit 计算，不能先在 16 bit 截断。这样避免 100 路宽加法器。

激活 bypass 保留 signed [-128,127]；ReLU 下界为 0；ReLU6 上界为 raw 96。输入 RGB 的 0…255 数值需预处理后才能按 signed Q4.4 使用；像素输入不能直接解释为 signed 8 bit而不做转换。

Q4.4 是否保持目标网络精度，需要逐层标定、溢出统计和图像集对比。硬件能运算不等于已证明模型精度。

## 6. DSP 共用、偏置和流水

每个 PE 负责一个固定空间位置。100 个 PE 同时接受不同像素，权重/控制信号广播。DSP48 NORMAL 模式 19×18 乘法足够覆盖 8×16；DUAL 的 11×10 和 8×8 不能完整容纳 16 bit 权重，故不能据此将 DSP 数量减半。

建议固定 `M_SEL=P, N_SEL=W, W_SEL=X, W_REG=1`，内部反馈累加。根据时序启用 A/B、P 和 O 内部寄存器；反馈使用 W，不使用移位后的 O。这样乘法前端的流水深度增加也不必使相邻 MAC 相隔多个周期。

**题设“norm 的 b 从 C 口进入”存在两项限制：**

1. 同一组 DSP 的 N_SEL 是实例参数，不能随指令切换 W 和 C。OP 控制加减，不能解决输入源动态切换。
2. `a_raw*x_raw` 有 12 个小数位，Q8.8 的偏置必须先变为 `b_raw<<4`。其完整范围需 signed 20 bit，而当前 EFX_DSP48 C 是 18 bit。只有额外限制 b 的范围到 [-32,31.99609375] 才可按此缩放完整放入 C 口。

资源优先方案：清零后先用 `A=16, B=b_raw` 执行一次 MAC，得到 b 对齐后的累加初值，再执行 `A=x_raw, B=a_raw`。norm 两个有效 MAC 周期完成，无须新增 DSP 或 100 路 LUT 偏置加法器。此方案改变题设的 C 口实现方式，但保持完整 Q8.8 算法结果。

若 C 口是硬性接口条件，必须另行设计偏置与反馈路径、范围约束或额外硬件；不能把该条件和“同一 DSP 内部反馈累加”视为已经同时满足。CASCIN 具有器件级级联连接约束，不能因为仿真端口有 48 bit 就承诺可随意从 fabric mux 驱动。

每条指令执行建议分为：锁存描述符、清累加器、发读请求、对齐数据/权重、连续 MAC、排空、后处理、写回、完成。

valid/first/last 需要与 DSP 数据延迟对齐。空拍不累加，最后输入拍不等于最后结果拍。DW 读邻域时可以暂停 W；若输入和乘法流水继续运行，W 的 CE 使用延迟后的 MAC-valid，不能让 stale product 重复累加。清 W、前端寄存器运行和尾部输出捕获的关系必须在 PE 仿真中验证。

## 7. PW 调度

PW 单通道：读取 1 个 tile 和 1 个权重，100 路并行乘法，最终量化，再激活/池化/写回。若使用舍入预置，额外发出 1 个常数 MAC。

PW 多通道：一个指令默认生成**一个空间 tile 的一个输出通道**。连续读取 `src_base+c` 和 `weight_base+c`，100 个 DSP 分别累计自身空间位置的结果。数据/权重读返回流水对齐后，可每拍接受一个通道 tile，最多 32 个。

32 通道指令得到的是 100 个输出像素，不是一次产生 32 个输出通道。Cout 个输出通道需 Cout 次运行或硬件输出通道循环。

如要覆盖输入通道多于 32 的网络层，可用不超过 32 的分段指令，并增加 INIT/CONTINUE/FINAL 累加语义。中间指令不清 W、不量化、不写普通 cache；必须紧邻且保持同一输出 tile/输出通道，不可穿插其他计算。更完整的实现是在单条宏指令内部遍历多个通道组。

## 8. DW 缓存与寻址

要求的卷积核按 Kh×Kw 支持：1×2、2×1、2×2、3×3、7×7。偶数核必须定义 anchor；建议 1×2/2×1/2×2 使用 anchor=(0,0)，3×3=(1,1)，7×7=(3,3)。这里采用常见神经网络 cross-correlation 顺序，不翻转核；若模型需要数学卷积，编译器应重排权重。

对于 stride=1、dilation=1 的 10×10 输出，输入有效范围为 `(10+Kh-1)×(10+Kw-1)`；7×7 最大为 16×16。跨 cache tile 时可能访问周围 3×3 共 9 个 tile，但不需要保存完整 30×30。

```text
9 个完整 tile 寄存器：9×100×8 = 7200 FF
紧凑 halo 寄存器：16×16×8 = 2048 FF
```

建议 16×16 halo 中主 tile 固定在 [3..12]×[3..12]。其余边带宽度为 3。根据当前 kernel 只加载所需部分：3×3 有效邻域是 12×12，7×7 是 16×16。主 tile 到达后可先执行与 anchor 对应的 tap，再补齐邻域，符合“主 tile 先算”的流程。

无 padding 的局部寻址：

```text
main_addr + dy_tile*row_pitch + dx_tile*tile_pitch
dy_tile, dx_tile ∈ {-1,0,1}
```

tile_pitch 通常为 Cstore，row_pitch 为局部矩形列数×Cstore。采用加减法和预先给定 pitch，避免运行时乘除；输入地址越界必须被拦截，不能让 10 bit 地址自然回绕。

## 9. DW 固定接线移位和两档资源选择

halo 以环形排列实现固定方向移位，PE 取固定 10×10 窗口。移动的是已有寄存器内容，环形回绕只是内部排列，不是图像的环形 padding。

性能档：按蛇形遍历 tap，偶数行向右，奇数行向左，行间向下。主 tile 对应 tap 已先计算，后续遍历到它时只推进位置，不再 MAC。权重可由上层预排为“主 tap + 其余蛇形 tap”，从而参数 RAM 连续读。各窗口间的数据路由只是 LEFT/RIGHT/DOWN 的固定接线，避免每像素 49:1 动态选择器。

这种结构通常能在邻域准备后连续接受 tap，中心去重处有一个可优化的空拍；预定位和读返回可能另有少量空拍。7×7 每个输出 tile/通道仍是 49 次有效 100 路 MAC。

省 LUT 档：只保留固定向右和向下移位，按普通逐行 tap 顺序计算，行尾用循环向右移位恢复起始列。这会降低 halo 输入选择分支数量，但 7×7 每行要将偏移 6 恢复为 0，即额外旋转约 10 拍；全指令时间明显增加。可每行保持 7 个连续 tap，再在行间等待。

**如果蛇形档综合后超过 10000 LUT4，应优先接受行间少量或更多等待，而不改变 100 DSP 阵列，也不采用 9-tile 寄存器缓存。**同一 DW 尽量流水化是优化目标，不能同时把最低 LUT 和完全无空拍当作已证明的结果。

padding loader、halo 的 load/shift 选择、PW/DW 输入选择仍需要 LUT。该方案去掉大 crossbar，并不代表拼接逻辑为零成本。

## 10. Padding 语义

反射 1、反射 3 指同一反射规则的宽度；仍需定义是否重复边界像素。建议默认 REFLECT 不重复边界：

```text
[-1] -> [1], [-2] -> [2], [-3] -> [3]
[W] -> [W-2], [W+1] -> [W-3], [W+2] -> [W-4]
```

若重复边界则为 SYMMETRIC，左侧 [-1] 会映射 [0]，两种规则不能混用。小特征图可能需要重复反射映射，不能总套一次公式。

内部 tile 接缝从相邻 tile 获取真实像素，只有 feature-map 外边界才 padding。用 LEFT/RIGHT/TOP/BOTTOM 四个独立标志表达位置，比“左上/右下…”枚举更灵活；有效宽高另行表示最后一块不足 10 个像素的情况。

7×7、stride=1 要保持 SAME 输出通常需要两侧各 pad 3；3×3 对应 pad 1。7×7 若只 pad 1，则单轴输出长度为 W-4，不能仍按 W 写回。偶数核的 SAME padding 必须不对称，例如 1×2 的左 0 右 1；只有“pad 1/3”一个对称宽度字段不足以完整定义偶数核输出。

为了节省 LUT，padding 映射主要在 halo 装载阶段执行，公共位置译码尽量共享；不应在 100 个 PE 的每个 tap 都做任意坐标反射、除法和像素选择。

## 11. 激活、池化和输出形状

最终 DSP 结果量化/饱和到 8 bit，再做 100 路激活及可选最大池化，避免 100 路 32/48 bit 池化比较器。

2×2、stride=2 的最大池化：25 组×每组 3 个二输入比较器，共 75 个比较器。第一级 50 个比较结果，400 bit 寄存器；第二级 25 个结果，200 bit 寄存器；共 600 FF，忽略少量 valid 控制。

无激活直接池化时使用 signed 比较；不合法像素不能以 0 代替后参与含负数最大池化，应采用有效掩码或最小值，并根据输出形状决定哪些窗口有效。

ReLU 与最大池化可以交换顺序，因为 ReLU 单调。若资源最紧，可在池化开启时只对 25 个结果激活，并保留非池化时的 100 路能力。第一版为对齐需求和便于验证，可保持“100 路激活→池化”。该交换不适用于一般非单调激活或其他池化定义。

例如初始 320×240 经 pool 后是 160×120；多级下采样会出现 20×15 等尺寸，最后 tile 部分有效，不能只用行 tile 长表示所有几何信息。

MobileNet 的 stride=2 卷积不等于 stride=1 卷积再最大池化。若需真正 stride=2，可以从 100 个 stride=1 结果中固定选取 25 个正确相位位置，再按象限合并输出；这是下采样选择，不是 maxpool，并且依赖正确的 padding/输出坐标约定。

## 12. 指令和控制模块

建议 128 bit 指令，FIFO 深度 4；采用 valid/ready，只有 complete 后弹出下一条计算指令。控制逻辑无需做跨指令流水或复杂 scoreboard。

建议指令或上下文寄存器覆盖这些字段：

| 字段 | 用途 |
|---|---|
| opcode | PW、DW、NORM，以及可选 CONV/配置 |
| src/dst_base | cache 起始地址，基础为 10 bit |
| param_base | 参数 RAM 地址，位宽由实际深度定义 |
| Cin_minus1 | 1…32，5 bit 编码 |
| tile_pitch / row_pitch | 局部 cache 寻址；可放上下文寄存器 |
| kernel / anchor | 五种核、偶数核锚点约定 |
| pad_kind / pad_extent / edge_mask | 零或反射，宽度 1/3，四边标志 |
| valid_w / valid_h | 部分 tile 的有效像素范围 |
| act / pool / stride | 后处理和采样方式 |
| write_mode | FULL/TL/TR/BL/BR |
| acc_init / acc_final | 超过 32 通道分段累加扩展 |
| repeat / increments | 可选简单循环，减少指令带宽 |

这只是字段建议，最终 bit map 尚未冻结。指令译码锁存一次，kernel/padding 公共计算共享；不要为每个 PE 复制完整译码或地址 FSM。

推荐模块分工：instruction FIFO/decoder、共享 sequencer、cache read controller、parameter reader、halo loader/shifter、PE array、requant/activation、maxpool、cache write controller、完成/错误状态。

读控制区分 request_valid 与 response_valid；写控制等待最后结果与目标掩码有效；busy/done/errors 对外可见。DW 禁止未完成读取就覆盖输入邻域，源/目标重叠必须经调度器明确保证安全。FIFO 仅有 4 条缓冲并不能独立存下整网的指令。

## 13. MobileNet 运算覆盖

题设支持 DW、PW、逐通道 affine norm、ReLU/最大池化，但不自动覆盖完整 MobileNet：

- 常见输入 stem 是 RGB 多通道普通 3×3 卷积，不是 DW；需要扩展 channel×tap 双重循环，或明确交给外部处理。
- DW stride=2 应采用真实卷积采样，不能用最大池化替代。
- 很多层 Cin 超过 32，需要分段保留累加或内部宏指令循环。
- BN 可折叠到离线权重和偏置，但偏置精度/范围仍需明确。
- 若目标版本含 ReLU6、残差加法、全局平均池化、分类头，需要明确支持范围；它们不在当前最大池化描述中。

建议基础计算单元先实现题设算子；若验收要求整网推理，再把指定网络的逐层表转成 ISA/调度需求。不能仅把三个 RGB 通道分别 DW 后再 PW 就当作任意 RGB 普通卷积等价实现。

## 14. 资源预算和优化顺序

BRAM 估算假设参数 RAM 为 4096×16 或 8192×16；用户尚未规定参数 RAM 深度，不能把 2×16 参数寄存器理解为参数 RAM 容量。

| 资源 | 基础预算/估算 | 可信度 |
|---|---|---|
| DSP48 | 100 | 一 lane 一个 NORMAL DSP 的结构用量；不含外部系统 |
| cache BRAM10K | 80 | 原生 1024×10×80 组织的确定值 |
| 参数 BRAM10K | 8 或 16 | 按 512×16 拼4096/8192深度的示例 |
| 额外 BRAM | 0–数片 | FIFO 可用 FF；可选权重/工作缓存另计 |
| fabric FF | 约 5000–6500 | 紧凑 halo、8 bit 后处理、DSP 内部寄存器条件下 |
| LUT4，省 LUT 档 | 目标约 8000–10000，可能超出 | 固定移位、共享 padding、固定量化、象限接线；需综合 |
| LUT4，蛇形性能档 | 初估约 9000–12000 | load/多方向 mux、反射和量化实现影响显著 |

FF 基础账本：800 输入 + 2048 halo + 800 量化/激活输出 + 600 pool + 512 FIFO + 128 当前指令 + 约 200–500 控制/参数，共约 5088–5388；部分输出寄存器可复用，额外 800 bit 写保持/预取可将其推到约 6000。不要无条件增加多个 800 bit 乒乓寄存器。

上述 FF 指 fabric FF，DSP/BRAM 内部专用寄存器单独看映射；最终以 Efinity 报告口径为准。

关键优化顺序：

1. 100 路 MAC 累加必须打包进 DSP，不能让 100×32 bit 累加器落到 LUT/FF。
2. halo 仅保存实际邻域，不存 9 个完整 tile。
3. 原生 1024×10 cache，避免双 bank 800 bit 读 mux。
4. 量化采用固定移位，舍入常数尽量在 DSP 中预置。
5. 8 bit 池化；象限 write-enable 避免 read-modify-write。
6. 反射映射尽量在装载阶段共享，必要时用更多装载周期降低 mux 宽度。
7. 根据首次综合结果选择蛇形档或单向档，接受行间空拍换 LUT。

这些数字不是实测，不含摄像头接口、DMA/DDR/HyperRAM、总线及完整网络调度器。不能用芯片总逻辑资源足够来代替用户要求的 <10000 LUT4、<8000 FF 验收。

## 15. 吞吐估算

100 DSP 每拍执行 100 MAC；若系统实际达到 200 MHz，则峰值 20 GMAC/s（将乘和加分别计为操作时为 40 GOPS）。200 MHz 只是举例目标，不是已验证频率。

| 模式 | 每 tile/输出通道的有效 MAC 发射拍数 |
|---|---|
| PW Cin=1 | 1；舍入/偏置预置可另加 1 |
| PW Cin=32 | 32；预置可另加 1 |
| NORM | 2：bias 预置、a*x；舍入可合并入预置 |
| DW 1×2 / 2×1 | 2 |
| DW 2×2 | 4 |
| DW 3×3 | 9 |
| DW 7×7 | 49 |

实际指令时间还包括译码/清零、cache/参数读延迟、halo 装载、tap 位置移动、DSP 排空、后处理和写回。蛇形 DW7×7 可以以约 60–85 拍作为初步仿真预算；单向省 LUT 档可能约 120–145 拍。均非确定时序，需结合实际流水寄存器和 padding loader 仿真修正。

例如原分辨率 PW 32→32：有效运算量为 768×32×32×100 = 78643200 MAC；仅有效发射需 786432 拍。在 200 MHz 举例下理想核心时间 3.93216 ms，实际会增加指令固定开销、块搬运和参数供给时间。没有完整网络逐层信息及外存带宽，不能给可信整网 FPS。

若每个 tile 的每个输出通道发一条 128 bit 指令，上例需 24576 条，即每帧 393216 byte 指令；4 深 FIFO 只解决短期供给波动。可用简单 repeat/地址递增循环降低指令带宽和单通道短指令开销。

## 16. 已完成验证与工具环境

已定位 Efinity 2026.1：`D:/Efinity/2026.1`，命令入口 `bin/efx_run.bat`。已定位 Conda：`D:/Users/Administrator/anaconda3`，halo 软件检查使用其 Python。系统还安装 Icarus Verilog。

验证文件：

- `docs/analysis/primitive_checks.sv`：工程现有 cache 模型的按片写掩码、写禁止、读 valid；单个 DSP 的 W 反馈连续 MAC、CE 保持、清零、全范围 Q8.8 偏置预置、符号乘法与移位。
- `docs/analysis/check_halo.py`：五种核的固定移位蛇形索引；主 tap 去重；每 tap 全部 100 个空间位置的映射；图像容量和 BRAM 算术。

运行结果均 PASS。DSP 检查没有开启 A/B/P 前端寄存器，因此不能据此宣称流水 PE 已验证。halo 检查是软件索引验证，不是 halo RTL/padding loader 仿真。

复现命令（PowerShell、工程目录）：

```powershell
iverilog -g2012 -s primitive_checks -I ip/bram_10kb -o docs/analysis/primitive_checks.vvp docs/analysis/primitive_checks.sv conv_mem/mem/mem_800_512.v conv_mem/conv_mem_unit/bram_10kb.v conv_mem/conv_mem_unit/efx_ram10.v yilisi_sim_models/efx_dsp48.v
vvp docs/analysis/primitive_checks.vvp
& 'D:\Users\Administrator\anaconda3\python.exe' docs/analysis/check_halo.py
```

没有完整顶层 RTL，本次没有执行整机 Efinity 综合、PnR 或时序收敛；也没有网络精度测试。

## 17. 建议实现与验收顺序

1. 冻结字节/象限布局、定点舍入饱和、偶数核 anchor、反射边界规则和局部地址 pitch。
2. 实现 native 800×1024 cache，并验证象限写入不破坏其他象限。
3. 单 PE 验证流水累加、空拍、首末 tap、偏置和饱和，再复制到 100 PE；先做一次综合确认 MAC 打包。
4. PW/NORM 路径跑通，再接 100 路激活与 25 路两级 pool。
5. DW3×3/7×7 实现 compact halo；分别综合蛇形与省 LUT 结构，再选定版本。
6. 加指令 FIFO/译码和统一 sequencer，验证 cache 回写完成后才报告 done。
7. 用 Conda Python 整数 golden model 做随机、极值、边界、偶数核和暂停恢复比对，检查每指令的周期和地址序列。
8. Efinity 2026.1 在 Ti60 F225 上综合/PnR；验收 DSP、BRAM、fabric FF、LUT4、时序，并对 LUT 风险进行实测调整。

如需要完整 MobileNet 推理，随后增加指定网络的 stem 普通卷积、>32 通道分段、真实 stride=2、必要的残差/平均池化以及外存块调度。

## 18. 官方核对来源

- [Ti60 产品规格](https://www.efinixinc.com/shop/ti60.php)：160 DSP、256 个 10K RAM 的芯片总量；用户设定的核心上限更严格。
- [Titanium Primitives User Guide v4.2](https://www.efinixinc.com/support/docsdl.php?pn=UG-TIPRIM&s=ef)：DSP48 端口/静态参数/反馈及 RAM 组织。具体逻辑推导同时依据工程内模型。

最终建议：先以 **100 DSP、80 cache BRAM、compact halo、内部累加、bias 预置、固定量化、象限掩码写回** 为主架构；优先确保功能与 FF/BRAM 预算，再以真实综合结果决定 DW 蛇形连续性与 LUT 成本的取舍。
