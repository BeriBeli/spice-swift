# Spicy 动态颜色分界检查

Spicy 也会出现竖向颜色跳变，现象并非 spice-swift 独有。仅回看目前已有代表画面，**CocoaSpice 最严重**：密集窄竖条覆盖大部分动态区域；spice-swift 多见少数明显分界，Spicy 既有单一跳变也有局部多条纹，后两者尚不能稳定排出先后。这是画面现象的定性判断，不是同步、等条件的量化排名，也未确认三者是否同一根因。

本轮 Spicy 只检查竖条。性能对比仍仅限 spice-swift 与 CocoaSpice，没有测量或发布 Spicy 的 CPU、输入延迟或 FPS。用户要求不复测后，没有新增动态测试，只回看截图并清理环境。

## 实际观察

Spicy 0.43 测试包正常连接原 Linux Lite，原生放大控件使其进入1920×1080 points全屏。用户手动打开本轮页面并完成Arm；随后只注入一次Space，启动有限120秒渐变动画。页面沿用此前160×90平滑渐变的颜色推进方式，不含固有竖条或逐帧文字覆盖。

条件为同一Linux Lite、配置1920×1080、QEMU `gtk,gl=off`、临时 `streaming-video=all`。原始窗口PNG为3840×2224，视频区为[0,64,3840,2160]。截图尺寸不冒称GPU drawable尺寸。

保存了24张动态图、开始及停止后各1张静态图。两批动态截图相对宿主启动键调用的实际区间分别为10.001–15.569秒、101.311–106.612秒；后者文件仍沿用`middle`标签，但没有将其写成计划的40秒采样。静态收尾图在约142.311秒取得。这些时间仅用于描述截图时段，不是输入延迟或输出FPS。

动态原图中可见贯穿画面的竖向分界，代表边界位于原图x≈3200（视频宽度约5/6处）。固定于采样前的像素候选规则，在9条采样行比较横向8像素跨度：最大通道差至少24、并覆盖至少7行时算强候选。24张动态图中15张达到强候选，18张达到至少3行的候选；开始/停止后的静态图均没有该候选。动态最大差为61/255，静态开始/结束最大差分别为3/2。此计数只描述这批截图，不是总体竖条发生率或流畅度排名。

代表动态图及无调色的局部裁图：

- [整图预览](/Users/beribeli/.codex/visualizations/2026/11/13/01a1d38a-15ea-7ed0-972e-9943ba463118/spice-spicy-visual-2026-11-15/spicy-early-08-preview.png)
- [原像素局部](/Users/beribeli/.codex/visualizations/2026/11/13/01a1d38a-15ea-7ed0-972e-9943ba463118/spice-spicy-visual-2026-11-15/spicy-early-08-detail.png)
- [后段多条纹](/Users/beribeli/.codex/visualizations/2026/11/13/01a1d38a-15ea-7ed0-972e-9943ba463118/spice-spicy-visual-2026-11-15/spicy-middle-05-preview.png)
- [停止后静态图](/Users/beribeli/.codex/visualizations/2026/11/13/01a1d38a-15ea-7ed0-972e-9943ba463118/spice-spicy-visual-2026-11-15/spicy-settled-00-preview.png)

原始结果：[RESULTS_SPICY_VISUAL_2026-11-15.json](../Benchmarks/Session/RESULTS_SPICY_VISUAL_2026-11-15.json)。[截图及数据包](/Users/beribeli/.codex/visualizations/2026/11/13/01a1d38a-15ea-7ed0-972e-9943ba463118/spice-spicy-visual-2026-11-15.zip) 含逐文件SHA256，未放入窗口控制脚本、应用、库或连接文件。

## 清理

按用户要求，已删除本机CocoaSpice、Spicy临时测试应用及源码/构建缓存，并移除工作目录中的窗口控制脚本、程序与工作副本，约240MiB。原Maspice安装及共享Homebrew库未改。报告、截图和历史证据包保留；历史证据包按原校验值留存，未改写其内容。

Linux Lite在清理前已恢复默认off。原Maspice进程随后退出，marker0恢复未完成，未继续GUI重试。额外清理客体Spicy页面时SSH连接失败，因此该远端页面未确认删除。详见[清理记录](../Benchmarks/Session/CLEANUP_NATIVE_COMPARISONS_2026-11-15.json)。
