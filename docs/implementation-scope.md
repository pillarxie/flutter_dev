# 阶段一：首个可运行增量

依据 `technical-design.md` 从空目录开始。当前增量建立三个桌面宿主骨架、正式 flutter_rust_bridge 桥接、Rust 权威会话模型和可操作工作台。

实现项目包识别、显式/FVM/自动 SDK 解析、daemon 设备发现和模拟器启动、DAP launch/attach、停止/解除附加、手动热更新、基本调试请求与有界日志。Flutter 只维护选择、当前事件投影和可见日志页。

主线程负责脚手架、桥接和集成。子任务分别实现 Rust 协议/SDK/进程基础、Rust daemon/会话控制、Flutter 工作台。完成后独立审查并执行协议、会话和界面验证。

SDK 基线以本机 Flutter 3.38.3 / Dart 3.10.1 为首个验证样本，Rust 1.95.0；桥接固定稳定版。跨平台构建使用 CI，不能用 macOS 构建证明 Windows/Linux 已验收。

后续增量继续完成：配置兼容和持久化、文件监听、完整断点及源码视图、内嵌 DevTools、测试树、跨平台真实设备回归及性能预算。外部浏览器入口只作为 DevTools 的恢复入口。此增量不代表阶段一所有完成标准已通过。

涉及实际子进程的验证只操作测试创建或本工具拥有的进程；应用通过 DAP 启动目标，核心不额外执行 flutter run。

## 原生网络参数面板增量

会话 DevTools 页现在提供原生 HTTP 请求面板，聚焦编码参数难以阅读的问题。复用当前 DAP 的 VM Service profiling，Query 和表单字段仅解码一层、保留重复项，JSON 与字段中的 JSON 缩进显示，支持原始内容切换与复制。首版限已连接且启用调试的 Debug 会话；Inspector / Performance 等官方内嵌页面仍未接入。具体能力、容量和验证边界见 README 与 validation.md。

## 官方 DevTools 模块增量

2026年10月14日接入官方 Inspector、Performance、CPU Profiler、Memory、Logging。Rust 按会话懒启动匹配 SDK 的服务并拥有进程生命周期；Flutter 复用一个原生 WebView，处理模式、迟到响应、会话切换、主题和重连，离开时释放。网络页继续使用原生解码面板。macOS 应用内已实际验证；Windows 已实现 WebView2 并提供运行库检查，实机待验收；Linux 内嵌明确未完成。官方 Debugger 隐藏，源码断点与单步继续由现有 DAP 面板负责。

## 日常开发效率增强

2026年10月15日补充六项能力：运行草稿/上次启动/多套命名配置原子保存，Rust 会话内 Dart 文件监控与自动热重载，网络 cURL/方法状态筛选/响应搜索/全部展开收起，日志错误筛选及外部编辑器源码定位，工作台快捷键，以及独立 flutter test --machine 运行面板。测试初始按实际文件发现，名称由机器运行事件获取；核心拥有测试进程、快照和有界日志，面板关闭不停止，退出统一清理。实际验收和边界以最新 README、usage、compatibility-baseline 与 validation 记录为准，不沿用早期“尚未实现”的阶段描述。

同日继续增强自动热重载：按规范化项目路径共享系统文件监听，以低频有界扫描兜底，覆盖应用目录外的本地依赖；通过变更版本保留繁忙和重载期间的新保存，避免锁竞争漏触发。同一版本的编译失败不无限重试，不自动执行 pub get、热重启或原生重新构建。方案见 [自动热重载监听与可靠性增强](epic/2026-10-15-auto-reload-watcher.md)，本次执行证据见 validation.md 最新记录。
