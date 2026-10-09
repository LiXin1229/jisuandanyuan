# 实现规格 v1（历史基线）

> 本文保留 v1 基线规格。v2 的 cache、ISA 扩展、固定模型 ROM 和总线切片掩码见 [CycleGAN 实现记录](cyclegan_iteration1.md)；最新后处理、执行时间和资源以 [第二轮效率记录](executor_efficiency_iteration2.md) 为准。以下 1024 深 cache、50 个 DW BRAM、并行后处理和保留位定义不再描述当前 RTL。v2 保持其余低 90 bit 指令与量化规则兼容。

## 数据与内存

数据 signed 8 bit Q4.4，参数 signed 16 bit Q8.8。每次乘法的小数位数为 12，最终右移 8 bit。默认算术截断；rounding 开启时将 +128 预置到累加器，等价于 `floor((S+128)/256)`，平局向正方向。最后饱和到 [-128,127]，ReLU 的下限 0，ReLU6 的上限 raw 96。

cache 为 800×1024，由 80 个 true dual-port 1024×10 BRAM 构成。端口 A 为主机，端口 B 为计算；主机内存访问仅在核心空闲时接受。两个端口不得同址冲突读写。

cache 每地址内，TL/TR/BL/BR 四个 5×5 象限依次排列，各 200 bit；象限内按行排列。像素位索引：

```text
p=((r/5)*2+c/5)*25+(r%5)*5+c%5
data[p*8 +: 8] = signed8 pixel(r,c)
```

同一空间位置的 PW 输入通道连续放置。DW 主 tile 地址由指令给出，相邻空间 tile 地址使用局部 tile_pitch/row_pitch 加减。feature-map 全局几何由上层转换为 edges 和有效宽高，不能把全图行跨度误当作局部 cache 步长。

参数 RAM 为 4096×16。PW 权重连续；NORM 参数为 `[a,b]`；DW 参数按 Kh×Kw 行优先排列，不翻转卷积核。2×16 parameter_buffer 保存当前返回和前一次返回的参数，数据和参数同时送到 DSP 前端。

## 128 bit 指令

| 位 | 字段 | 定义 |
|---|---|---|
| 3:0 | opcode | 0 PW、1 NORM、2 DW、3 NOP |
| 13:4 | src | cache 主/首 tile 地址 |
| 23:14 | dst | cache 输出 tile 地址 |
| 35:24 | parameter | 参数首地址 |
| 40:36 | Cin-1 | PW 1～32；NORM 必须为 0；DW 只计算一个通道 |
| 43:41 | kernel | 0=1×2、1=2×1、2=2×2、3=3×3、4=7×7；Kh×Kw |
| 45:44 | activation | 0 bypass、1 ReLU、2 ReLU6 |
| 46 | pool | 2×2、stride=2、VALID 最大池化 |
| 49:47 | write | 0 FULL、1 TL、2 TR、3 BL、4 BR |
| 51:50 | padding | 0 NONE、1 ZERO、2 REFLECT |
| 53:52 | pad_width | 0、1、3；反射宽度，不是反射规则编号 |
| 57:54 | edges | bit0 左、bit1 右、bit2 上、bit3 下 |
| 61:58 | valid_w-1 | 1～10 个有效输入/输出主 tile 列 |
| 65:62 | valid_h-1 | 1～10 个有效输入/输出主 tile 行 |
| 75:66 | tile_pitch | DW 相邻空间 tile 地址间隔 |
| 85:76 | row_pitch | DW 局部 cache 矩形行间隔 |
| 86 | rounding | 预置 +128，最后右移 8 |
| 87 | keep_acc | 保留前一段 PW 的累加结果 |
| 88 | more_acc | 当前 PW 还不是最后一段，不量化/写回 |
| 89 | stride2 | 不做 maxpool，固定抽取 (0,2,4,6,8)×(0,2,4,6,8) |
| 127:90 | reserved | 必须为 0 |

NOP 同样要求保留位、有效宽高及枚举字段合法，但不会访问参数或数据。

每条 PW 产生一个输出通道。32 个输出通道需要 32 条指令。分段 PW 以 more_acc=1 开始，后续 keep_acc=1，最后 more_acc=0；dst 和 rounding 必须相同。各段之间不得插入会清累加器的计算。上限为 256 个累计输入通道，以保证后处理的 signed32 数值范围；每段仍不超过 32。NOP 和主机访问不改变 DSP 累加器。

错误码：0 成功、1 指令/范围/续算条件非法、2 DW 邻接地址越界、15 内部状态错误。done 对错误指令同样产生一次脉冲，该指令不写 cache；无效 continuation 保留尚未消费的 partial sum，下一条合法指令可恢复。

pool 和 stride2 不能同时打开。任一 25 像素输出模式必须选择一个象限，FULL 非法。正常 100 像素输出可以 FULL 或只写其一个对应象限。未写象限保持原内容，写入完成不意味着四个象限全部有效。

## DW 几何与资源选择

anchor：1×2、2×1、2×2 为 (0,0)，3×3 为 (1,1)，7×7 为 (3,3)。每个输出仍以主 tile 的 10×10 位置为锚定位置；偶数核相当于向右/下取额外像素。这是神经网络 cross-correlation。

边界 DW 必须给出覆盖所需 halo 的 padding：7×7 用宽度 3，其他核至少 1；NONE 用于没有 feature-map 外边界的内部 tile。当前 ISA 不输出尺寸缩小的 VALID 边界卷积，需要上层另行规划工作块和输出几何。

REFLECT 不重复边界像素：[-1]→[1]，[W]→[W-2]。维度为 1 时重复唯一像素，维度为 2/3 使用等价的周期三角映射。内部 tile 接缝读真实邻接 tile，不能执行 padding。

流程：

1. 主 tile 先进入 PE，计算 anchor tap。
2. 最多读取其余 8 个邻接 tile，仅采集 16×16 halo 需要的像素；主 tile 放在 halo 坐标 [3..12]×[3..12]。
3. 256 个 halo 像素逐拍写入 10 个一致的 narrow BRAM 副本，每副本负责一个输出列的并行读取。
4. 每 tap 以 10 像素/拍读取 10 行，执行零/反射映射，预排为 800 bit window。40 个 512×20 BRAM 保存所有 tap 窗口。
5. 参数和 800 bit window 同步逐拍读取到 PE。再次经过 anchor tap 时不累加，其他 tap 连续发射。
6. 最后一个 MAC 经过 DSP A/B、P、W、O 后再后处理、写回。

该版本用 50 个 DW BRAM 换取较少 LUT，未使用原评估中的寄存器旋转 halo。window 预排约每 tap 12 拍；DW 的 PE 计算部分仍以一拍一个 tap 工作，anchor 去重处有一个空拍。后续可以在资源允许时优化装载，但必须重新综合和验证。

## PW/NORM 与后处理

PW 发读请求每拍一个通道，cache/参数返回、input_tile 和 parameter_buffer 对齐，100 个 DSP 使用内部 W 反馈。空拍只停 W 的 CE，乘法前端仍运行。最后输入与最后输出的 valid 独立延迟，不通过计数猜测写回时机。

NORM 先执行 `16*b_raw` 预置偏置，再执行 `x_raw*a_raw`。rounding 时预置改为 `16*(sign_extend(b_raw)+8)`；广播侧使用 18 bit，避免 16 bit 溢出。这保持完整 Q8.8 偏置范围，改变了原设想的 C 口偏置路径。

100 个结果同时量化/激活。池化保持两级 25 个四输入最大树：第一拍 50 个 pair maxima，第二拍 25 个结果，总 75 个 signed8 比较器。部分有效 tile 只输出完整 2×2 窗口，其余位置为零。

stride2 是真实卷积结果的固定相位抽样，与最大池化不同。需要上层按指定网络的 padding/锚点/输出相位配置；四个 5×5 结果合并为输出 tile 时，必须属于同一通道并且空间坐标对应。

## 32 bit 主机接口

`mobilenet_bus_top` 是同步、**字地址**总线。bus_wr/bus_rd 和地址/数据保持到 bus_ready，在上升沿接受；主机必须将等待中的操作保持稳定。读接受后 bus_rvalid/bus_rdata 更新。建议 bus_wr 与 bus_rd 互斥。

| 字地址 | 访问 | 内容 |
|---|---|---|
| 0 | R | bit0 busy、bit1 done_sticky、bit2 memory_ready、bits7:4 error、bits11:9 FIFO count |
| 0 | W | bit1=1 清 done_sticky；不复位计算单元 |
| 1 | R/W | cache_address[9:0] |
| 2 | R/W | cache 象限写掩码[3:0]，默认 1111 |
| 3 | W | 提交 tile_staging 到 cache_address |
| 4 | W | 读取 cache_address，返回值自动载入 tile_staging |
| 5 | R/W | 参数地址[11:0] |
| 6 | W | 写参数[15:0]，地址自动 +1（最后地址后自然回绕） |
| 7 | W | 提交 command_staging 到指令 FIFO |
| 8～11 | R/W | command_staging 的四个 32 bit word，低字在前 |
| 32～56 | R/W | tile_staging 的 25 个 32 bit word，低字在前 |

cache/参数提交在 busy 时 backpressure；指令提交在 FIFO 满时 backpressure。写 staging 寄存器不自动提交。tile_staging 同时用于写暂存和读快照，读 cache 会覆盖之前暂存的数据；不要与读快照返回同时写 staging。

done_sticky 应在一轮命令前 W1C，或以 FIFO count/busy 跟踪多指令批次；连续提交多条指令时，sticky 本身不表示整批已完成。核心 done 则每条指令一个脉冲。

reset 同步取消当前指令和排队指令，清状态/FIFO/partial sum，不清 BRAM 存储内容。取消前已经完成的写入仍保留。reset 之前从未写过的 cache/参数内容不能视为有效数据。

## 复现与范围

运行 `scripts/run_sim.ps1`、`scripts/run_synthesis.ps1`、`scripts/run_pnr.ps1` 和 `scripts/run_postmap_sim.ps1`。生成数据、日志和网表在 build 目录，指令编码工具为 `tools/mn_codec.py`。4 深 FIFO 使用显式寄存器，不依赖综合器将异步读取数组转换为同步 BRAM。

示例：

```powershell
& 'D:\Users\Administrator\anaconda3\python.exe' tools/mn_codec.py --operation pw --src 100 --dst 900 --parameter 505 --channels 32 --activation relu --rounding
& 'D:\Users\Administrator\anaconda3\python.exe' tools/mn_codec.py --operation dw --src 100 --dst 900 --parameter 1000 --kernel 7x7 --tile-pitch 2 --row-pitch 12 --padding reflect --pad-width 3 --edges 0x5
```

本版是题设计算核心，不包含 RGB 普通卷积 stem、完整 MobileNet 层调度、模型参数、外存 DMA、残差或全局平均池化。320×240 RGB 需 2304 个 tile，不能一次全放入 1024 地址 cache，必须按局部工作块处理。
