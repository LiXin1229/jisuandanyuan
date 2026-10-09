# test.jpg 整网板级复验

输入为 `C:/Users/Administrator/Desktop/jisuan/pe10_10/test.jpg`，与用户附图逐字节相同，320×240 RGB，没有缩放。JPEG SHA256 为 `b6c4b5ebdb8185d0c7aec20423ba19eb7b736fa1fe788bcd4ff8b9688cf911bf`。

网络使用 `ac1fbbc` 中的完整生成器：三层编码、九个残差块、三层转置卷积、7×7 输出与 Tanh，Q4.4 激活、Q8.8 参数和固定归一化。复验沿用第四阶段的已验证 bitstream，计算 RTL 与资源配置没有修改。

从 JPEG 和原始 epoch11 checkpoint 重新生成独立整数参考，使用直接 scatter 定义转置卷积；再通过独立的编码指令模型逐层检查全部 16 个输出张量。确认新导出参数、Tanh 表与当前部署完全一致后重新烧录 Ti60。

板上先上传图片并逐字节核对输入 DDR，再逐块回读九个残差块、三层转置卷积和最终 RGB；随后用同一张 JPEG 再运行一次不暂停的完整网络。最终输出按 DDR 中每 tile 两个 50 字节有效半块重建，独立检查 RGB PNG 的全部像素。

验证通过，共比较 1,651,200 个激活值，全部零差异。两次最终输出各包含 230,400 个 RGB 字节（320×240×3），共 460,800 字节，最大绝对误差和平均绝对误差均为 0；从板上字节重建的两张 PNG 也与新生成的软件参考逐像素一致。

| 运行模式 | 比较的激活值 | 差异数 | 整网周期 | 150 MHz 计算时间 | 指令等待周期 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 分层暂停回读 | 1,420,800 | 0 | 6,991,621 | 46.61081 ms | 0 |
| 整网连续运行 | 230,400 | 0 | 6,991,866 | 46.61244 ms | 0 |

上述时间为板上计算计数，不包含 JTAG 图片上传与结果回读时间。连续运行的数据等待计数为 405,826 周期，指令等待为 0。输入 DDR 全量回读、计算输入 CRC、九个残差块和三个转置卷积的完成计数、7×7/Tanh 输出完成标志均通过。

本次确认的是硬件与当前定点、固定归一化模型的数值一致性。回读图像仍有可见的纹理失真；相对原始浮点模型的量化及固定归一化画质误差未在本次测试中评估。验证没有修改 RTL，因此沿用第四阶段的资源及布局布线结果。

## 复现及输出

```powershell
./scripts/run_test_image_board.ps1
# 也可指定另一个 320×240 输入文件：
./scripts/run_test_image_board.ps1 -Image 'C:/path/image.jpg'
```

输入副本、重新生成的模型参考、JTAG 日志和回读图像位于 `build/test_jpg_verification`。`input.png` 为解码后的输入，`instruction_reference.png` 为软件参考，`paused/board_output.png` 与 `continuous/board_output.png` 为两次板上输出。机器可检查的完整证据见 [验证记录](analysis/cyclegan_test_jpg_verification.json)。
