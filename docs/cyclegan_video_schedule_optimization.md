# 实时 CycleGAN 邻域装载调度优化

本轮以 `8e2cb67` 的实时视频版本为基线，计算时钟仍为 171.428571 MHz，DDR UI 仍为 96 MHz。网络尺寸、全部层、权重、固定归一化、量化和 HDMI 显示格式保持原配置。

## 减少转置卷积的无效装载

转置卷积已被分解为 1×1、1×2、2×1、2×2 四相卷积。此前后三相每条指令均装载中心及八个 halo tile；每个 halo 需要三次行/列写入。前向锚点的完整 10×10 tile 实际只使用右侧和下侧邻域。

`mobilenet_unit.sv` 复用现有 `owner` 状态寄存器，调整中心 tile 之后的装载次序：

| 空间核 | 原邻域 | 当前邻域 | 每条指令节省 |
| --- | --- | --- | ---: |
| 1×2 | 中心＋八个 halo | 中心、右侧 | 21 拍 |
| 2×1 | 中心＋八个 halo | 中心、下侧 | 21 拍 |
| 2×2 | 中心＋八个 halo | 中心、右侧、下侧、右下角 | 15 拍 |

优化条件为 `kernel<3 && valid_w==10 && valid_h==10`。不足 10×10 的部分 tile 仍装载完整邻域，因为窄边界的反射补边可能读取相反方向的 halo。3×3、7×7、1×1、PW、NORM、ADD 的流程保留原样。

三个转置卷积阶段每相分别执行 `12×16×32=6144`、`48×8×16=6144`、`192×8×8=12288` 个通道任务，合计减少 `(21+21+15)×24576=1400832` 个计算时钟。板上计算侧忙碌计数从 **6375696** 降为 **4974864**，与这一计算完全一致。此计数包含装窗及后处理，不等同于纯 MAC 时间。

DDR 响应稳定等待、缓存行所有权、最终输出槽背压和 HDMI 紧急补行优先级继续保留。没有增加帧缓存、计算阵列或预取数据寄存器。

## 资源与时序

| 资源 | 基线 | 当前 | 增量 |
| --- | ---: | ---: | ---: |
| LUT4 | 26126 | 26141 | +15 |
| FF | 12987 | 12988 | +1 |
| BRAM | 249 | 249 / 256 | 0 |
| DSP48 | 103 | 103 | 0 |

映射、布局布线和码流生成均通过。计算域 setup/hold 余量 **0.427/0.035 ns**；全部已分析时钟关系非负，所有关系的最小 setup/hold 余量为 **0.156/0.029 ns**。

## 验证

新增 138 个用例覆盖三种前向核的所有边界掩码、零填充、反射填充及宽高仅剩 1～2 像素的部分 tile。共 **339 个用例、390 条指令**通过真实 DSP/BRAM 模型的数值比较和逐条周期检查，总线回归也通过。

普通图像的逐层暂停整网仿真、反色图像在 45 拍基础 DDR 延迟下的连续整网仿真均通过。每组执行 170880 条指令，检查 1075200 个解码/输出值及 345600 个残差值，指令等待均为 0；全前缀分别为 5487453 / 6674653 拍。原生算术仿真沿用 150 MHz 计算时钟，171.43 MHz 的实际配置另由视频板级协议仿真、布线时序和真实上板数值比较验证。

七项视频接口仿真全部通过，覆盖摄像头裁剪、ISP、池化、采集、按键、HDMI 拥塞以及整板调度/所有权。协议模型不承担网络算术验收。证据工具仅允许计算侧 `mobilenet_unit.sv` 改动，并核对实际原生仿真副本与上板 RTL、两组参考输入和数值向量的 SHA256。

## 上板结果

两种模式均执行完整网络，各等待 60 秒，并按含计数读取开销的实际单调时钟间隔计算帧率。HDMI 刷新仍为约 60 Hz，下面是整网完成帧率。

| 显示模式 | 基线 FPS | 当前 FPS | 提升 | 完成帧数 |
| --- | ---: | ---: | ---: | ---: |
| 网络结果 | 23.06695 | **27.55983** | **19.48%** | 1679 |
| 配对原图 | 23.99199 | **28.78335** | **19.97%** | 1754 |

合计 3433 帧，HDMI 欠载、采集 FIFO 溢出、裁剪过载和原图校验错误均为 0，指令等待计数为 0。八次软件显示模式切换通过，结束后恢复实体按键控制；本轮未新增人工目视或实体按键按压确认。

摄像头帧 5317 的实际输入 CRC 为 1830635236，与回读原图重新量化的 CRC 一致。由 epoch11 checkpoint 为该图像重新生成整数 scatter 参考，再核对指令模型全部 16 层张量；最终 230400 个 RGB 字节零差异，最大误差及 MAE 均为 0。原图/结果 HDMI 校验和为 76289936 / 78994520，分别与对应 DDR 数据按两倍缩放计算的校验和一致。

完整证据见 [本轮机器验证记录](analysis/cyclegan_video_schedule_optimization.json)。历史 [上一轮帧率记录](cyclegan_video_fps_optimization.md) 及其 JSON 保留。

## 工程与复现

当前码流 SHA256：`1c5350211a835ad7a1498b97b60efd5b1c6ca6ff06f8c05d48212d6e334b862f`。完整 Efinity 工程位于本工程的 `build/video_board_schedule2/encoder_board.xml`，原 `build/video_board` 保留上一版。源码、IP、约束、映射/布线报告和码流共 148 个文件已逐一校验复制；活动工程路径已指向新目录。

```powershell
./scripts/run_unit_modelsim.ps1
New-Item -ItemType Directory -Force build/video_schedule2_verified | Out-Null
Copy-Item build/sim/unit.log,build/sim/bus.log,build/sim/commands.csv,build/sim/executor_cycles.log build/video_schedule2_verified
Copy-Item build/stage2/unit_staging_path.txt build/video_schedule2_verified
./scripts/run_output_modelsim.ps1 -OutputDir build/video_schedule2_verified/full_native
./scripts/run_output_modelsim.ps1 -Inverted -DdrDelay 45 -Continuous -OutputDir build/video_schedule2_verified/full_native_inverted
./scripts/run_video_modelsim.ps1 -OutputDir build/video_schedule2_verified
./scripts/run_video_modelsim.ps1 -Tests board -OutputDir build/video_schedule2_verified
./scripts/run_video_board.ps1 -OutputDir build/video_schedule2_verified -Program
./scripts/verify_video_board.ps1 -OutputDir build/video_schedule2_verified `
  -RecordPath docs/analysis/cyclegan_video_schedule_optimization.json `
  -Baseline docs/analysis/cyclegan_video_fps_optimization.json
```

同一次会话的旧版本短测保存在 `baseline_style.json` 和 `baseline_original.json`；它们验证旧码流身份及相同计算频率下的忙碌周期变化，校验结果也纳入本轮 JSON。复现时若没有这两个短测文件，工具改用历史 60 秒记录中的稳定忙碌计数比较。长时间整网仿真可与硬件测试并行，硬件验证脚本加 `-DeferRecord` 时只保存实时测试证据，最终仍须运行 `verify_video_deployment.py --record` 完成全部验收。

复制后的中文工程路径由 JTAG 工具按 UTF-8 读取，避免 Windows 默认 CP936 导致活动工程路径误解码。
