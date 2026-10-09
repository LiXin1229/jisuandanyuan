# 第四阶段：7×7 输出卷积与 Tanh

本阶段把第三阶段的 `8×240×320` Q4.4 特征接入最后的 7×7 卷积和 Tanh，生成 `3×240×320` uint8 RGB 图像。编码、九个残差块、三层转置卷积和输出层均由 FPGA 自主调度；固定归一化参数沿用 epoch11 checkpoint。主机仅上传 RGB、启动和回读验收。

## 计算与缓存

继续使用同一个 100 DSP 计算阵列及 `cyclegan_decoder_scheduler`。`OUTPUT_ENABLE=1` 时，调度器在三层转置卷积之后执行第四个配置，不增加独立计算器、DMA 或 DDR 写通道。每个输出 tile/channel 依次执行八条 7×7 CONV，累加 392 项。第一条清累加器，中间条保留累加器，最后一条完成 Tanh；所有八条指令保持 `tanh=1`、`rounding=0`，不先把卷积结果截断成 int8。

输出权重位于 Q8.8 参数地址 `20427..21602`，共 1176 个；卷积无 bias，也没有输出归一化。输出使用三像素 reflection padding，显式标记图像四边，并提供上/下环形行地址。Tanh 复用已有 Q4.8 到 uint8 的表：`(acc+8)>>4` 后饱和到 `[-2048,2047]`，查表产生图像字节。

7×7 会读取当前 tile 的上、下、左、右及角邻域，因此输出输入区采用四行环形缓存，每行 `32×8=256` 个 tile，占既有 cache 地址 `0..1023`。当前行 y 执行时保留 y-1、y、y+1，同时预取 y+2；每完成整行的最后一个输出通道，释放后续可复用的行。加载 y+2 只覆盖 y-2，不破坏上邻域。所有行仍存放在原有 feature cache，未增加 feature BRAM。

输出槽复用 `1424/1428` 两个 tile，按完整输出次序交替分配，槽号为 `co[0] ^ x[0]`。3 个输出通道是奇数，这样可避免跨 tile 时连续占用同一槽。一个槽等待 DDR B 响应时，下一个槽可继续计算；输出无需转置卷积的四相交织，直接分两半送入原有 400 bit writer。原有输入 DMA、读桥、写桥和上传/特征写仲裁器继续共用。只有活动调度阶段的匹配 writeback 才能发布结果，保留第三阶段防止编码池化写回污染调度元数据的检查。

## DDR 与调试

最终输出位于 `0x00600000..0x00647fff`，共 2304 个 10×10 tile，每 tile 128 字节，channel-major，tile 内四个 5×5 quadrant 的顺序不变。每半 tile 64 字节：低 50 字节有效，高 14 字节为零。前三层转置特征仍位于 `0x00300000/0x00400000/0x00500000`。

板级签名为 `0xe315`，计算 150 MHz、DDR UI 96 MHz、DDR PHY 384 MHz，相位 6。VIO 输入仍为 832 bit，统计复用 800 bit 回读邮箱，没有增加宽调试探针。统计索引 0..15 沿用第三阶段；16 为输出层周期，17 bit0 为输出完成。输出周期复用当前层周期寄存器，没有额外复制 32 bit 计数器。

`pause_each_block=1` 可逐个暂停九个残差块、三层转置卷积及最终输出，等 DDR B 响应完成后才发布暂停。三层转置结束后 `layers_completed=3`，最终输出额外通过 `output_completed` 标记；整网 `done` 在最终输出完成后产生。连续模式不依赖主机逐层恢复。

## 复现

在工程根目录执行：

```powershell
./scripts/run_output_modelsim.ps1
./scripts/run_output_modelsim.ps1 -OutputOnly -Inverted -DdrDelay 45 -Continuous
./scripts/run_unit_modelsim.ps1
./scripts/run_output_board.ps1 -Program -RepeatBoot
$modelPython='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $modelPython tools/record_output_deployment.py
```

输出模型参考来自 `build/cyclegan_model`，构建结果保存在 `build/stage4_verified`。构建脚本要求 map/pnr/pgm 均明确 PASS、150 MHz 所有 setup/hold 关系均无负余量、DSP 为 100 且 BRAM 不超过器件容量，并核对构建 RTL 哈希后才允许下载。验收脚本检查输入 DDR、CRC、帧序、每层逐值结果和 DDR 填充；将板上输出重建为 `board_output.png` 和 `board_output_inverted.png`。

## 验证结果

完整 DDR/JTAG 网表为 **22804 LUT4、12323 FF、100 DSP48、0 DSP24、222 BRAM**（52 RAM10 + 170 DPRAM10）。相比第三阶段增加 2168 LUT、939 FF 和 4 BRAM。4 BRAM 中，2 个保存剩余输出权重，2 个用于 Tanh；计算阵列、feature cache 和 DDR 传输缓冲未扩容。计算时钟 150 MHz 的 setup/hold 余量为 **0.799/0.035 ns**，所有受约束时钟关系均通过。

两次下载、四帧验收通过：首次 normal/inverted 两帧逐块回读九个残差块、三层转置卷积和最终 RGB，并逐字节核对输入 DDR；重新下载后的两帧执行整网不暂停，回读最终 RGB。共 **3302400 个激活值零差异**，其中最终输出合计 921600 个字节全部匹配独立整数参考。两种输入的实际流 CRC 为 `326d32e8/f9ff144f`，帧号为 0/1，残差 9 块、转置 3 层、输出完成标记均正确。

板上整网计算时间 **46.608..46.613 ms**，其中输出层约 **12.711 ms**；不包含主机上传、回读及人为暂停。所有验收帧的指令供应等待为 **0**。数据等待统计表示调度器尚未获得必需行的周期，可与 FIFO 中已发出的计算重叠，不能直接当作总闲置时间。

真实 RTL 整网仿真从 RGB DDR 开始，共执行 170880 条指令，逐值检查 345600 个残差值及 1075200 个转置/最终输出值，验证两级时钟 CDC、随机 AXI 回压、逐层暂停以及全部 DDR 填充。另以 inverted 输入、DDR 延迟 45 拍进行连续输出层仿真，核对全部 230400 个输出字节，并断言所有输出槽跨通道/tile/行严格交替。计算单元 201 个用例、252 条指令和总线回归通过；未修改的写仲裁器沿用第三阶段 40 个并发事务及 AW/W/B 回压的已核对证据。

输出槽交替优化在相同 inverted、DDR 延迟 45、连续模式的 RTL 仿真中，将输出周期从 2122164 降至 1967953，减少 154211 拍（7.27%），仅增加 5 LUT，FF/BRAM/DSP 不变。

完整证据、各帧统计、资源/时序报告及 RTL/bitstream 哈希见 [验证证据](analysis/cyclegan_stage4_deployment.json)。
