# 残差区同帧实例归一化

本轮在九个残差块的 **18 个归一化点、576 个通道**恢复当前帧的实例归一化。每个通道统计完整 30×40 的 1200 个值，使用总体方差和 epsilon=1e-5。编码器的 5 个点及转置卷积的 3 个点仍使用固定归一化，后续按阶段接入。

## 计算与调度

100 路主 PE 和现有 NORM 指令继续负责 `a*x+b`。旁路统计每拍处理 4 个 signed8 Q4.4 值，积累 S、Q；不复制 800 bit tile，直接在下一条卷积完成前扫描后处理保持的数据。每个 tile 扫描 25 拍，平方累加再用 1 拍收尾。残差 DW/PW 的写回间隔足够覆盖该扫描；后续短 PW 场景需要重新验算保持时间。

共享一套易灵思 **SINGLE 开根 IP 和 PIPELINE=0 的除法 IP**。一个通道只在 1200 个样本到齐后计算系数，期间主 PE 继续算后续通道。原厂 ModelSim 专用加密模型用于除法仿真，综合使用原厂综合源；没有用行为除法替代原厂 IP。

定义 `D=N*Q-S*S`，`R=floor(sqrt((D<<32)+round(256*N*N*2^32/100000)))`，按下式生成 signed16 Q8.8 系数：

```
a = sat16(round_even(gamma*N*2^20/R))
b = sat16(round_even((beta*R-gamma*S*2^16)/R))
y = sat8((x*a+16*b+128)>>8)
```

b 使用未舍入的乘积独立计算。DW 后保留 ReLU，PW 后归一化再加 skip，ADD 继续采用原来的饱和与舍入规则。该整数约定见 `tools/live_norm_reference.py`，不宣称与浮点 PyTorch 逐 bit 相同。

每个残差块按以下顺序运行：

1. DW 按通道连续计算十二个 tile，同时统计并生成系数。
2. 读动态系数执行 DW NORM/ReLU。
3. PW 按输出通道连续计算十二个 tile，同时统计并生成系数。
4. 执行 PW NORM 和 skip ADD。

缓存 A 保留输入/skip，地址1056..1439；B 为 DW 特征，地址0..383，tile 内通道连续；C 为 PW 特征，地址384..767，通道内 tile 连续。前八块原位更新 A，最后一块在 PW 全部完成后写回0..383，衔接现有解码器。三个完整特征图使用1152个 tile，均在现有 cache 中，没有新增特征 DDR 读写。

## 耗时与资源

原厂 IP 系数测试覆盖260组，包括四种样本数、零方差、正负极值和计算中复位重启。每通道系数耗时 **248 拍**，短于残差 DW/PW 计算一个通道的时间。

576组系数及345600个残差输出值在原生 RTL 中逐值一致。残差区执行指令仍为17280条，主 PE 忙碌425088拍；总耗时由442395增至 **442926拍**。增加的 **531拍=3.0975微秒** 是统计收尾及阶段屏障，系数计算与卷积重叠。指令供应等待计数为0；必要的统计屏障计入残差总周期。

4路统计已经满足残差 DW/PW 的写回间隔。改成8路只能将每个 tile 的扫描从25拍减到13拍，理论上十八次阶段收尾最多再省216拍、约1.26微秒，却需要额外平方运算通道和数据选择逻辑，因此本轮采用4路。

| 资源 | 固定归一化版本 | 本轮 | 增量 |
| --- | ---: | ---: | ---: |
| LUT4 | 26141 | 28367 | +2226 |
| FF | 12988 | 14537 | +1549 |
| BRAM | 249 | 253/256 | +4 |
| DSP48 | 103 | 104 | +1 |
| DSP24 | 0 | 4 | +4 |

新增3块BRAM保存原始 gamma/beta，1块保存当前归一化点的32组动态系数；没有为每个通道复制开根/除法或为每个点保存整套统计 RAM。计算时钟仍为171.43 MHz，布局布线 compute setup/hold 余量为 **0.048/0.030 ns**，所有已约束时钟关系均通过。

## 工程和验证

当前视频工程：`build/video_board_instance_residual/encoder_board.xml`。历史固定归一化工程保留在 `build/video_board_schedule2`。新码流 SHA256：`1a5d4a809514794bb2b31882def46f4485c2c93052aad795b37ef32393e2bdcb`。

验证记录及实时帧对保存于 `build/video_instance_residual_verified`，仿真证据保存于 `build/instance_residual_verified`。最终验收记录见 [机器验证 JSON](analysis/cyclegan_residual_instance_norm.json)。实时帧率应结合模式、采样区间和 DDR 争用比较；本轮目标是恢复同帧归一化并控制额外计算时间。

普通 test.jpg 分层暂停、反色图像连续执行且 DDR 延迟45拍，两组完整原生仿真均通过：每组1075200个解码/输出值、345600个残差值一致，170880条指令，供应等待为0。板端摄像头帧4094的230400个RGB字节与新整数参考零差异，输入CRC和两种显示的HDMI校验和均匹配。两种显示模式各配置30秒持续采样，合计1742个网络帧：**风格27.54 FPS、原图28.77 FPS**，视频下溢、采集溢出及原图校验错误均为0，最后恢复实体按键控制。该帧率与历史固定归一化基线接近，不把采样波动解释为提速。

```powershell
$modelPython='C:\Users\Administrator\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
& $modelPython -B tools/prepare_instance_norm_model.py
& $modelPython -B tools/prepare_instance_norm_deployment.py
./scripts/run_instance_norm_coeff.ps1
./scripts/run_unit_modelsim.ps1
./scripts/run_instance_norm_modelsim.ps1 -Seeded -Continuous
./scripts/run_instance_norm_modelsim.ps1 -FullOutput
./scripts/run_instance_norm_modelsim.ps1 -FullOutput -Inverted -Continuous -DdrDelay 45 -ReuseAssets
./scripts/run_video_board.ps1 -OutputDir build/video_instance_residual_verified -Program
./scripts/verify_instance_norm_board.ps1 -DeferRecord
# 对该码流采集同帧输入/输出，再运行：
& $modelPython -B tools/verify_instance_norm_deployment.py --pair build/video_instance_residual_verified/live_pair
& $modelPython -B tools/verify_instance_norm_deployment.py --record
```

后续编码器需要完整通道统计屏障和原始池化暂存；转置卷积需要把统计与 DDR 输出及下一层装载结合。当前旁路统计的4路配置按残差卷积间隔设计，不能直接假定首层短 PW 也能隐藏扫描。
