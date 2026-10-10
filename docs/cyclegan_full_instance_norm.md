# 全网当前帧实例归一化

26 个归一化点的实现共用一套四像素统计器、一套非连续开根/除法 IP 和原计算单元。编码器点 0..4、残差点 5..22、解码器点 23..25；共 688 个通道。参数使用原模型 Q8.8 gamma/beta，每次输入重新统计，不使用上一帧系数。

编码器原来的小块流水不能直接满足全帧统计，因此新增共享 DDR 归一化扫描：2 MiB 保存量化后的卷积结果，3 MiB 保存归一化及池化结果。逐通道读入已有特征缓存，每通道最多 768 个块，加载与四像素统计重叠；系数完成后用 NORM 指令处理。编码器最后一次池化直接写缓存 1056..1439，继续使用原来的残差调度。

解码器先完成四个转置卷积子相位并交织成完整特征图，再在原 DDR 地址上执行共享归一化扫描和 ReLU，随后开始下一层。保留原裁剪、量化、边界处理和最终 7×7/Tanh 输出。

阶段一已经完成 23 点上板验证：五个编码器点加十八个残差点，解码器暂用固定系数。`camera_original.png` 仅作为 RGBx 输入上传；读回 230,400 个 FPGA 输出字节，全部与 23 点整数参考一致，HDMI 校验和一致，命令等待为零。整帧 10,004,513 个周期，171.428571 MHz 下为 58.35966 ms。

阶段一静态图工程资源为 LUT 28,034、FF 14,300、BRAM 241、DSP48 101、DSP24 4；相同静态输入壳的十八点版本为 LUT 26,418、FF 14,114、BRAM 241、DSP48 101、DSP24 4。布线设置和保持时序全部通过。

阶段一证据见 [cyclegan_encoder_instance_norm.json](analysis/cyclegan_encoder_instance_norm.json)，对应 Git `2f103b6`。

完整二十六点实时摄像头版本已完成一帧逐像素验证：摄像头原图与网络结果成对读回，230,400 个输出字节全部等于当前帧实例归一化参考，16 个指令模型阶段张量也全部一致。风格图及原图模式分别持续测试 30 秒，切换测试、自动按键控制恢复均通过；HDMI 欠载、采集溢出、原图校验错误、指令等待均为零。

| 工程 | LUT | FF | BRAM | DSP48 | DSP24 | 设置/保持余量 ns |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 原十八点实时摄像头 | 28367 | 14537 | 253 | 104 | 4 | 0.048 / 0.030 |
| 全二十六点实时摄像头 | 29802 | 14722 | 253 | 104 | 4 | 0.115 / 0.035 |
| 全二十六点静态实拍图 | 27954 | 14299 | 241 | 101 | 4 | 0.274 / 0.035 |

开根/除法继续共用单套 IP。修改了系数舍入的组合逻辑：商的高位只参与饱和判断，低 16 位加舍入进位，避免 64 位加法、比较、取负串联。四种采样数的 260 组边界测试通过，单通道最大延迟仍为 248 周期，舍入规则和饱和结果保持一致。

实拍图全帧为 11,997,781 个计算时钟周期，即 69.98706 ms；其中计算单元忙碌仍为 4,974,864 周期。实时显示风格图时测得 12.02 帧/秒，显示原图时为 13.84 帧/秒，HDMI 时序仍为 60 Hz。完整实例归一化需要新增全图统计屏障和 DDR 中间结果传输，因此帧率低于原十八点版本；IP 的开根/除法不是当前主要耗时。

工程已保存在当前工程目录：

- 实时摄像头：`build/video_instance_full_live_final/project/encoder_board.xml`。
- 实拍图 HDMI：`build/video_instance_full_photo_final/project/encoder_board.xml`。
- 已读回的实拍图输出：`build/video_instance_full_photo_final/photo_pair/fpga_styled.png`。
- 实时采集数值证据：`build/video_instance_full_live_final/live_pair/comparison.json`。

完整证据由 `tools/record_full_instance_norm.py` 汇总到 [cyclegan_full_instance_norm.json](analysis/cyclegan_full_instance_norm.json)。复现全部流程使用 `scripts/verify_full_instance_norm.ps1`，包含系数边界测试、两组真实计算 RTL 全帧仿真、视频协议仿真、实时摄像头上板和静态实拍图上板。已经生成完整证据后，可用 `-ReuseSimulation -ReuseBuild -ReuseCapture` 复用相应工件；最终证据检查仍会校验 RTL 散列和逐像素结果。

真实计算 RTL 两组回归均已通过：原实拍图逐层暂停、反色图连续执行并增加 DDR 延迟。每组检查 688 组归一化系数、268,800 个编码器输出数值、345,600 个残差输出数值和 1,075,200 个解码器/最终输出数值；总指令 170,880，DDR 读请求 76,800，归一化及最终输出写半块 21,504，指令等待为零。两组全帧周期分别为 9,577,750 与 17,942,623（仿真 DDR 延迟不同，不能代替板端耗时）。原十八点兼容模式的 576 组系数和全部残差结果也已回归通过。

实拍图 FPGA 输出另与参考工程 `analysis/normalization_choices_20261008_final/phone_test/all.png` 对比，230,400 个 RGB 值完全相同。当前上板为静态实拍图工程，HDMI 控制为 7，固定显示完整二十六点网络输出。恢复实时摄像头可运行：

```powershell
./scripts/run_video_board.ps1 -NormPoints 26 -ReuseBuild -Program -OutputDir build/video_instance_full_live_final
```

参数：`cyclegan_encoder.FULL_INSTANCE_NORM=0/1/2` 对应原十八点、编码器与残差二十三点、全二十六点。视频顶层 `INSTANCE_NORM_POINTS=18/23/26`；构建脚本 `run_video_board.ps1 -NormPoints 26`，`-HostImage` 选择静态图工程。
