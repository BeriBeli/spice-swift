# Native SPICE client comparison: measured baseline and blocked preflights

2026-11-15 续测状态见 [新报告](PERFORMANCE_NATIVE_CLIENT_STAGE_2026-11-15.md)。本文件保留 11 月 14 日阶段数据。

本轮尚未完成三端性能对照，不能据此判断 CocoaSpice 或 Spicy 比 SwiftSpice 快多少。Maspice 修复版已完成正式基线；CocoaSpice 已真实连接、显示和输入预检，但发生服务端无响应断连；Spicy 当前等待用户在正常文件选择框中选择原连接文件。未测得的数据保留为 `null`。

机器结果见 [RESULTS_NATIVE_CLIENT_STAGE_2026-11-14.json](/Users/beribeli/Workarea/spice-swift/Benchmarks/Session/RESULTS_NATIVE_CLIENT_STAGE_2026-11-14.json)。本记录是阶段结果，不表示测试、恢复或三端比较已经完成。

## 已测得的 Maspice 基线

同一持续运行的 Linux Lite QEMU PID 160169，4 vCPU、6144 MiB、1920×1080、QEMU GTK `gl=off`、SPICE `streaming-video=all`。使用原 `~/Downloads/linuxlite.vv` 的 CA、完整证书 subject 和票据，未改为其他连接文件。完整屏幕变色 fixture 为 750 字节，SHA256 `f48393b4a9b7cced1cce29fc7af837901f762986f22c5a2d87002610c7e62e2b`；请求 30 FPS，最多 5400 次定时器回调。请求频率不等于实际输出帧率。

Maspice 二进制 SHA256 为 `a96a051b6903d582af31632f220ad299570474870acbe66247561f80aefecbc4`，即本轮读回/原生接纳修复版。正式窗口内没有其他构建、测试或剖析进程。

| 项目 | 实测 |
| --- | ---: |
| 真实 Space 输入 | 40 次；画面依次确认 0、20、40 |
| Mac 客户端 CPU | 58.90% / 60.460544 秒 |
| Linux QEMU CPU | 54.42% / 60.106889 秒 |
| 客户端窗口末 RSS | 290.05 MiB |
| CPU 窗口对应负载年龄 | 91.396–151.661 秒 |
| 更宽的 Display 诊断区间 | 127.774 秒，负载年龄 38.348–166.122 秒 |
| 更宽区间 Display 接收速率 | 2.395944 MiB/s |
| 更宽区间 MJPEG 解码分片 | 92,430 |
| 更宽区间原生接纳分片 | 91,795 |
| 更宽区间读回 / GPU 错误 | 94 / 0 |
| 更宽区间额外 stream create | 0 |

CPU 的 100% 表示一个逻辑核满载。Mac 和 Linux 各用本机单调时钟计算实际区间，不跨主机相减。首次启动采集器的审批延迟使 CPU 窗口晚于原计划；之后客户端窗口应对齐负载开始约 90–150 秒。Display 计数覆盖更宽区间，不能用作严格同期的 CPU 工作量分母。Marker 仅验证交付，不构成逐按键 RTT 或光子延迟测量。

## CocoaSpice：已真实连接，稳定性未通过

测试使用官方 [CocoaSpice](https://github.com/utmapp/CocoaSpice) commit `d8d29fc810047a3ddcebb351cdadc8fe4b4f308d`、UTM spice-gtk fork commit `2776f6346090aca7dd4087dd59848cd5f79deb90`，以及各自锁定的 spice-common/keycodemapdb/libucontext 来源。上游 tracked 源码未修改。测试宿主使用原 CSMain、CSConnection、CSDisplay、CSInput、CSMetalRenderer；这不是完整官方 UTM 应用的性能测试。

宿主与完整 UTM 的差异已经记录：复用本机 Homebrew 原生依赖、禁用本进程的 GStreamer 系统插件扫描、选择可用的显式插件注册、关闭非本轮工作负载所需的共享与音频/USB功能。MJPEG 仍走原生内建解码器。由于本机没有离线 Metal Toolchain，启动时编译同 revision 的原 Metal/header 源，再临时供原 bundle loader 使用；初始化后恢复 loader，编译排除于后续测量。低频聚合诊断与方法计数也属于测试宿主，开销未校准。

已经定位并处理两项宿主集成问题：Homebrew GStreamer 系统插件扫描使 worker 启动阻塞；直接打开 Downloads 内的原 `.vv` 会停在系统 `open`。宿主现使用正常 NSOpenPanel 选择原文件，在文件访问作用域内读入内存，没有复制票据文件、保存 bookmark 或修改全局权限。PID 11806 的事件记录显示，选择完成后原文件在同一毫秒读入成功，随后 main/display/cursor/inputs 四个 TLS 通道均 OPENED。

真实预检的窗口为 1024×768 points，内容 1024×736 points，drawable 2048×1472 pixels，客体 1920×1080，scale 1.0667。CPU canvas 的两份 1920×1080 图像完整；宿主输入焦点、Space down/up 和未禁用输入状态也已记录。初次局部画面、黑屏及后续断连尚未定位到最终根因，不能作为有效的帧率或 CPU 结果。

事件历史确认：PID 11806 四个通道从 OPENED 至 CLOSED 分别为 main 60.164 秒、display 60.072 秒、inputs 60.057 秒、cursor 60.059 秒；没有 GError 或 delegate error。服务器 QEMU 日志出现 `unresponsive`。官方 server 的 `RedChannelClient::connectivity_timer` 在发送/ACK阻塞或已发 PING 等待 PONG、持续没有进展时断开，不是普通空闲自动关连接。现有 socat 中继未发现 `-t`/`-T` 或已检查的 socket 超时选项。

这仍不足以区分传输/服务端、UTM native 集成、客户端调度或响应路径。下一次应在断开前采 worker 函数栈与通道进展，并与 stock Spicy 能否稳定超过 75 秒对照；不通过关掉服务端监控来制造稳定结果。CocoaSpice 正式 CPU、完整客体输出 FPS、40 次远端 marker 成功率均未取得。

## Spicy：启动与授权调查已完成，实测等待文件选择

本机已有 Homebrew spice-gtk 0.43 revision 1 / GTK 3.24.52 的 arm64 Spicy。它是 spice-gtk 测试查看器，和 virt-viewer 的 remote-viewer 是不同程序。stock Spicy 不直接解析 `.vv`，因此任务目录使用仅负责原连接配置和低频聚合端点的启动适配。原 GTK/SPICE 库、主程序机器指令 `__text` 保持不变；任务包重签及独立 LC_UUID 会改变完整可执行文件哈希，不能称整个文件逐字节不变。

旧包装出现过 TCP `GIO EHOSTUNREACH`，尚未到 TLS；另一次实测明确停在原 Downloads 文件的 `open`，并有对应 TCC 请求日志。旧 UUID 被系统映射到其他应用身份已经证实，但不能把所有网络错误都认定为 Local Network 拒绝。

当前包保留原 CA、完整 subject、票据、TLS-only/all secure，正常 NSOpenPanel 单文件授权，未复制 `.vv` 或修改 TCC 数据库。PID 12193 已进入正常 AppKit modal 事件等待；当前未在文件 `open`、GStreamer 扫描或互斥锁中等待。界面工具能列出应用在运行，却无法读取其文件选择窗口；已请求用户选择原 `~/Downloads/linuxlite.vv` 并点击 **Use Connection File**。在手动操作结束前保留该进程，不并行抢占会话。

替代的 GtkFileChooserNative 授权适配已在独立目录离线构建、自检，尚未安装或启动。GTK 3.24.52 官方 Quartz 实现使用 NSOpenPanel 的 completion/sheet 方式，并由 `gtk_native_dialog_run` 运行递归 GMainLoop；它是当前直接 AppKit `runModal` 路径的待验证替代，不能预先宣称已经解决界面可见性。

Spicy 的正式 CPU、40 次 marker 和变色竖线观察均未实测。其官方源码默认 MJPEG 使用较轻的 DCT/upsampling 选项及过期帧策略；已安装二进制的 `SPICE_QUALITY` 宏尚未直接核实，不能把源码默认写成实测质量。即使后续 CPU 较低，也必须同时报告接收量、尺寸、可见性及质量/丢帧差异。

## 竖线及下一步

Maspice 的同源 fullfield 正式基线仍可见竖向色彩相位分界，正式 CPU 后另保存了 10 张连续截图。CocoaSpice 的局部黑屏和断连属于尚未解决的预检问题；Spicy 尚未观察。当前没有证据证明换客户端即可消除之前所有测试中的竖线。

Spicy 官方源码逐 stream 按各自目标矩形更新共享 surface、发 invalidate，各 MJPEG decoder 独立按 mm_time 调度；不能先验保证全屏分片相位一致。后续应先完成参考客户端的同源观察，再把分界位置与 stream rectangle/mm_time 对照，决定呈现合并和服务端整帧路径的调整。[SPICE 协议](https://www.spice-space.org/spice-protocol.html)、[spice-gtk 0.43 官方源码包](https://www.spice-space.org/download/gtk/spice-gtk-0.43.tar.xz)

当前 VM 保持授权测试的 `all` 模式，以便完成用户文件选择后的对照。测试结束后仍需恢复默认 `off`、原安装 Maspice 和全屏 marker 0；本阶段未声称已恢复。

## 可审计证据

- Maspice 原始端点、marker、画面及计算器：`/Users/beribeli/Workarea/spice-mac/.build/spicy-comparison-20261114`。
- CocoaSpice 来源、宿主集成说明、构建记录、CPU canvas、函数栈与连接事件：`/Users/beribeli/Workarea/spice-mac/.build/cocoaspice-comparison-20261114`。
- 关键断连记录：`evidence/cocoa-connection-events-p11806.json`；当前文件选择状态：`direct-network/file-panel-events.jsonl`。
- 两张错误目标的预检截图及未完成的 Cocoa marker 序列已在 `evidence/preflight-observation-corrections.json` 标记排除。Maspice 正式基线发生在切换客户端前，未受影响。
- `analyze-native-stage.py` 可离线重算本阶段 JSON；未测得的客户端始终输出 `null`。没有 xctrace、环境导出、原始凭据日志或发布动作。

此前读回/原生接纳修复的真实 A/B 与验证结果另见 [PERFORMANCE_MJPEG_READBACK_2026-11-14.md](/Users/beribeli/Workarea/spice-swift/docs/PERFORMANCE_MJPEG_READBACK_2026-11-14.md)，不与本次尚未完成的跨客户端对照混合。
