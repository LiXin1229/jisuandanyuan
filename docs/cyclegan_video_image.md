# 摄像头实拍图片上板与 HDMI 显示

使用 `C:\Users\Administrator\Desktop\jisuan\pe10_10\camera_original.png` 的原始 320×240 RGB 像素，上传到 FPGA DDR，由当前计算单元完成整网，结果通过现有 HDMI 链路显示。图片已经是 ISP 输出的 RGB，不再重复进行 Bayer 解码。

这是静态图片验证模式。实时摄像头工程仍保留在 `build/video_board_instance_residual`；本次工程、位流和记录集中在 `build/video_image_verified`。当前板端保持处理结果，断电后需要重新下载位流和图片。

## 输入与计算

`cyclegan_camera_board` 新增默认关闭的 `HOST_IMAGE` 参数。验证项目将该参数设为1，以 JTAG RGBx 数据替换传感器输入，复用 `camera_frame_pingpong` 的输入缓存、DDR 写通道、原图配对、整网调度及 HDMI。这个模式裁剪传感器/ISP逻辑，不保存整幅图片到 BRAM。

每个上传命令携带64字节、16个RGBx像素，通过两个256位VIO输出端口传输。每8拍提交一个像素，命令在16个像素提交后应答；整帧只有在最后一次DDR写响应返回后才发布给计算调度器。主机上传4800个数据包，随后发起整网计算。主机没有上传网络结果。

签名为 `0xe317`，UUID 为 `e3177cfe3110414c8c948a9d7e1e3ac5`，与实时摄像头 `0xe316` 区分。命令1开始输入帧，命令2传输RGBx数据，命令3控制显示/运行，命令4读取质量指标，命令5读取性能指标，命令6回读DDR。

计算模块、参数ROM、残差同帧实例归一化和输出Tanh均复用上一版。实例归一化范围仍为残差区18个点、576通道，其余8个点使用固定归一化。

## 验证

- 固定图片链路仿真检查307200个上传RGBx字节、230400个输出字节、完整原图备份、DDR调试读、命令应答和冻结HDMI；检查无开始命令、重复开始、超额数据包的拒绝行为。
- 实时摄像头链路回归检查两帧460800个输出字节、DDR仲裁、跨时钟域及输出缓冲所有权。
- FPGA运行完成后，回读配对原图和处理结果；原图必须逐像素等于指定PNG，输出必须逐字节等于同一张图生成的整数参考。
- 整数参考同时通过16个指令模型张量的比较。原图和处理结果的HDMI像素和必须与回读DDR计算值一致，欠载和校验错误必须为0。
- 综合、布局布线、位流生成均通过，所有受约束时钟关系的setup/hold余量非负。完整计算RTL哈希与上一版原生整网仿真证据相同，复用其数值验证。

静态模式资源：26418 LUT4、14114 FF、241 BRAM（71 RAM10＋170 DPRAM10）、101 DSP48＋4 DSP24。计算时钟171.43 MHz，setup/hold余量0.121/0.035 ns。本图整网5928609拍、34.58 ms；指令等待0拍。上传耗时独立于整网计算时间。

验证工具将完整资源、时序、源文件哈希、图片哈希、上板计数、数值比较和HDMI校验写入 [验证记录](analysis/cyclegan_video_image.json)。板端回读效果图为 `build/video_image_verified/photo_pair/fpga_styled.png`。

## 复现

在工程目录的 PowerShell 7 中执行：

```powershell
./scripts/verify_video_image.ps1
```

复用已经生成的静态位流，重新下载并上传图片：

```powershell
./scripts/verify_video_image.ps1 -ReuseBuild
```

工具在ASCII临时目录运行Efinity，再将工程复制回当前工程 `build/video_image_verified/project/encoder_board.xml`，随后检查资源、时序和源文件后上板。板端活动工程记录在 `build/video_active_stage.txt`。最终控制值7表示暂停后续计算并显示处理结果；HDMI持续刷新这一帧。

原实时摄像头位流保留于 `build/video_board_instance_residual/outflow/encoder_board.bit`。
