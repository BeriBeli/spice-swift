# Native SPICE clients: real marker and CPU comparison

本轮取得了 Maspice 修复版和 CocoaSpice TLS 回移变体的实际对照。Cocoa 变体在这个负载中的客户端 CPU 低约 40.3%，QEMU CPU 较高；两端均完成真实 marker 40/40，也都出现竖向色彩相位分界。Spicy 未通过同 viewport 预检，没有可用于排名的 CPU 数据。尚未证明等画质、等完整帧率或竖线的唯一根因。

机器可读数据：[RESULTS_NATIVE_CLIENT_STAGE_2026-11-15.json](../Benchmarks/Session/RESULTS_NATIVE_CLIENT_STAGE_2026-11-15.json)。上一日基线保留在 [2026-11-14 阶段记录](PERFORMANCE_NATIVE_CLIENT_STAGE_2026-11-14.md)；本日数字不替换历史观测。

后续已完成[真实输入延迟与画面一致性补测](PERFORMANCE_NATIVE_VISIBLE_2026-11-15.md)。它使用新的可校验码图和连续窗口捕获，不能与本文渐变页CPU直接换算；Cocoa动态码失读的限制也单独记录。

归档：[本轮证据包](/Users/beribeli/.codex/visualizations/2026/11/13/01a1d38a-15ea-7ed0-972e-9943ba463118/spice-native-client-comparison-2026-11-15.zip)。包内含选定原始计数、窗口截图、来源及回移 patch、脚本、逐文件 SHA256 和离线检查器，不包含连接文件、应用或动态库。

## 本日正式测量

CPU 以占满一个逻辑核为 100%；每个主机分别用自己的 monotonic 计时。

| 客户端 | 客户端 CPU | QEMU CPU | 客户端 / server 实际区间 | marker | 动态竖向分界 |
| --- | ---: | ---: | --- | --- | --- |
| Maspice 修复版 | 46.5651% | 52.2587% | 59.993821 / 60.009119 s | 0→20→40，40/40 | 有 |
| CocoaSpice + 官方 TLS 单行回移 | 27.8099% | 56.5684% | 59.374837 / 59.361779 s | 0→20→40，40/40 | 有 |
| 未修补 CocoaSpice 宿主 | 未取得 | 未取得 | 约 60 s 后断连 | 未完成 | 未取得有效动态结果 |
| Spicy 包装宿主 | 未取得 | 未取得 | 未完成可比 viewport 预检 | 未完成 | 未取得有效动态结果 |

每个可用客户端仅测了一轮，以上不是统计显著性或通用性能排名。没有测得完整客体输出 FPS、逐键 RTT、物理呈现延迟或 GPU 时间；分片、上传、draw callbacks 都不能代替这些指标。

## 条件及对齐

两轮使用同一 Mac、同一 Linux Lite QEMU PID 160169、同一 fixture；两轮后再次复核服务器和源文件哈希不变。QEMU 为 4 vCPU、6144 MiB、`gtk,gl=off`、virtio 1920×1080，临时测试模式 `streaming-video=all`。完整 QEMU/SPICE/launcher/fixture 哈希在结果 JSON 中。

源页面为 750 字节的固定 fullfield HTML，160×90 canvas 放大至客体全屏，以 30 FPS 定时请求渐变色更新，5400 callbacks 后停止，名义约 180 秒。这是源配置，不是实测输出帧率。

两端实际主窗口外框均 1024×768 points；整窗截图均 2048×1536 pixels。Cocoa 诊断另实测 view 1024×736 points、Metal drawable 2048×1472 pixels、backing scale 2。本轮没有直接读取 Maspice 的实际 Metal drawable 尺寸，不能将整窗截图尺寸当作 drawable 证明。

采集器在 Start 点击前 armed，按实际宿主 mouse-down 派发锚点的年龄 90 和 150 秒分别采样。首个 Cocoa collector 耗时约 0.918 秒，所以实际 CPU 区间约 59.37 秒，未将其写成精确 60 秒。源锚点不等于客体动画启动或物理显示时刻；不进行跨主机、跨时钟域相减。正式窗口内没有构建、测试、剖析或额外截图序列。

Maspice 本轮诊断窗口关闭，产品在 dismiss 时关闭诊断收集；Cocoa 宿主保留自己的轻量计数。两端诊断开销未单独校准。旧基线 58.9% 与本日 46.6% 的诊断状态、时段不同，不能称为这次产品优化带来的 CPU 降幅。本轮没有修改 SwiftSpice 或 Maspice 产品代码。

Cocoa 的宽聚合计数另覆盖 212.219 秒：display 接收增量 685,662,280 bytes、canvas-copy 请求 16,033、accounted copy bytes 83,732,839,752、MTK draw callbacks 25,429。它不与正式 CPU 区间重合，不能用来归一该 CPU 或计算完整 FPS。本轮 Maspice 原生 AX 指标提取返回 0 行，保留为未取得，未用历史计数补齐。

## CocoaSpice 的连接问题及变体身份

测量对象是官方 [CocoaSpice](https://github.com/utmapp/CocoaSpice) commit `d8d29fc810047a3ddcebb351cdadc8fe4b4f308d` 的最小 AppKit/MTKView 宿主，UTM spice-gtk commit `2776f6346090aca7dd4087dd59848cd5f79deb90` 加一行官方 spice-gtk v0.43 TLS 缓冲读取检查。它不是未修改 CocoaSpice 或完整 UTM 应用的基准。

未修补原宿主 PID 30439 在含当前本地网络声明的 metadata 下再次失败：main/display/inputs/cursor 通道寿命分别 60.053、59.926、59.912、59.915 秒，均 CLOSED 后 delegate_disconnected，根代理没有提前请求断连。之前 PID 11806 为 60.057–60.164 秒。原版和变体 Info.plist 除 executable、identifier、name 三项身份字段外一致，因此仅补用途声明未消除原模式。

独立变体回移 `SSL_has_pending` 条件，允许 OS socket 无新可读事件时继续处理 OpenSSL 缓冲。来源和一行 patch 已核对。首次新包联网被系统提示中止、接收 0 bytes 的尝试排除；用户允许本地网络后重启，同一原文件建立四个 TLS 通道。

变体 PID 31419 在根代理主动 Quit 前持续约 **670.02 秒**，此前没有 CLOSED，完成实际 40/40 输入和正式动态 CPU 窗口。这支持该回移解决了本轮约 60 秒断连模式，但不是长期稳定性证明。首次连接的画面仍有大片黑色和局部碎片；Ctrl+R 后完整重绘恢复，此限制保留。

## 竖线证据及呈现路径

正式 CPU 后，两端各保存 10 张连续动态窗口截图。Maspice 的源年龄为 163.229–165.851 秒，Cocoa 为 174.509–177.078 秒，均在正式区间外且位于名义有限负载期间。两端均有竖向相位分界，说明换用 Cocoa 呈现实现没有自动消除问题，不能将其唯一归为本客户端的 currentDrawable 阻塞。

另一次短动态诊断中，Cocoa 原生 CPU canvas PNG 看起来平滑，而分别计时的 GPU 窗口有竖向分界。源码核对显示，非 GL 截图直接读取同一 primary CPU canvas；builtin MJPEG 经 put_image 写入该 canvas 后 invalidate，再由 canvas buffer 逐 rect blit 至 Metal texture。没有另一条视频 overlay 绕开该 canvas。

这些截图不是同一 revision、同一时刻的对照；PNG 编码和写盘还在 CSMain context 中同步执行，会暂停其其他回调。因此目前不能据“平滑 CPU 图 / 有分界 GPU 图”唯一判定 GPU 上传错误。

下一步应记录 stream rectangle / mm_time，并对齐同一 revision 的不可变 CPU 快照与 GPU texture 读回。若 CPU 快照已混合相位，继续定位源与 stream 调度；若 CPU 一致而 texture 混合，再修正上传批次、资源生命周期或发布边界。先取得这层证据，再选择合并呈现或服务端整帧路径，避免无证据地继续调整 currentDrawable。

## Spicy 的实际情况

本机 stock Spicy 基于 Homebrew spice-gtk 0.43 revision 1 / GTK 3.24.52。启动适配仅用于原文件读取、原 TLS 策略和低频端点；stock 主程序机器指令、GTK/SPICE 库保留。整文件哈希会因重签和任务 LC_UUID 改变，未称其完整逐字节相同。

最新 PID 34203 正常接受并读取原文件，四通道共同存在 155.358301 秒。初始窗口为 320×297；尝试调整 viewport 时有手势进入客体、随后进程消失的观测，四通道均 CLOSED、无错误，原因未知。未完成 40 次输入、正式 CPU、FPS 或有效动态竖线对照。

独立 GTK native chooser 候选 PID 33706 只进入文件选择，未接受原文件、没有真实 OPENED；根代理核验其精确路径后以 SIGTERM 结束。不能用该尝试评价渲染性能。

静态源码未把主 display 窗口设为不可缩放，也没有锁定 320 的 max-size；320×297 更符合 Retina 最小请求加窗口装饰。现有观测既不能证明 Spicy 无法缩放，也不能证明 resize 导致退出。启动集成和自动化的影响尚未排除，故不以静止或小 viewport 的低 CPU 发布排名。

## 操作纠正、恢复及验证

Computer Use 曾异常挂起约 4 小时 25 分钟，该时间不算测试或稳定运行。用户批准后改用仅操作指定客户端的本机窗口脚本。初版点击漏发 mouseMoved，部分尝试未点中目标；补齐移动后重新验证实际 marker 和正式源画面，失败尝试排除。Cocoa 正式源和 0/20/40 均已实际观察。一次路径浮层截图被系统合并进父窗口，查看前已裁到路径框并删除原图；路径浮层截图现禁用，未查看或归档连接文件预览。

测试已收尾：Linux Lite 正常重启为 PID 212333，启动项不再含 streaming-video，恢复默认 off；CentOS PID 26919、TLS relay PID 3368 和 launcher 未变。仅原安装 Maspice 0.6.1（SHA256 `cacc21837587f5a3b4ce47e6da66b5814d2a99657bcf32882ccc3a5087043fa1`）保持连接，客体为单一 Chrome marker 页面、全屏计数 0。所有对照宿主已退出，验证脚本没有解析 .vv 内容。

本轮验证包括：宿主脚本 clang warnings-as-errors、两组进程身份和 CPU 算术复核、截图归属与 0/20/40 观察、源/服务器哈希复核、恢复状态核验。前轮 757 SwiftSpice 常规测试、757 ASan、57 Maspice 测试结果继续保留，未冒称本轮重跑；本轮产品源码无新增改动。
