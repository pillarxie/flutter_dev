# 阶段一兼容基线

日期：2026年10月13日。当前是首个可运行增量，不是全部阶段一完成声明。

## 版本与构建

| 项目 | 当前基线 | 证据与边界 |
| --- | --- | --- |
| Flutter 宿主 | 3.38.3 / Dart 3.10.1 | 本机静态检查、测试、macOS release 构建 |
| Rust 编译器 | 1.95.0，edition 2021 | `rust/Cargo.toml` 最低编译器与 CI 一致 |
| 桥接 / 生成器 | 2.12.0 | Rust、Dart 和生成器固定同版；实际 FFI 测试 |
| 被调试 SDK | Flutter 3.38.3 | 唯一真实 SDK 验证样本；其他版本暂不宣称支持 |
| macOS | 本机 macOS 26.5.1 arm64 / Xcode 26.0 | release 构建与桌面样例调试；10.15 仅是脚手架部署下限，未验收 |
| Windows | CI 目标 windows-2022 | 骨架、DLL 打包及进程 Job Object 实现；远端 CI 尚未运行 |
| Linux | CI 目标 ubuntu-22.04 | 骨架、GTK 构建及 Unix 进程组实现；远端 CI 尚未运行 |
| Dart-Code | 暂未选定插件版本 | 当前以 SDK 内置 DAP 文档和协议为实现基线；插件兼容清单尚未完成 |

## 能力矩阵

| 能力 | 当前增量 | 验证范围 |
| --- | --- | --- |
| 多包项目识别 | pubspec Flutter dependency、缓存和软链接过滤、扫描上限 | Rust 测试，真实样例 |
| SDK | 项目显式路径、最近祖先 FVM、本包 VS Code 设置、持久全局默认和异常回退、环境自动发现 | 配置/回退测试、实际原生 API 与会话回退验证；正式 Finder 配置环境仍待独立验收 |
| 设备 | 按 SDK daemon、设备事件、模拟器列表及启动后等待设备可用 | 真实设备发现；模拟器启动为协议样例验证 |
| Run config | 入口、模式、Flavor、dart-define、env、参数数组、noDebug、attach URI | 有类型 API 和界面；launch.json 完整导入未实现 |
| launch | 单一 DAP 入口，initialize / initialized / configurationDone | 假适配器阻塞握手、实际 macOS 样例 |
| attach | SDK DAP attach；disconnect 时 terminateDebuggee=false | 协议样例验证；真实外部应用存活回归尚未执行 |
| 会话 | 核心权威快照、代次/序号过滤、多会话、取消及终态清理 | 进程所有权、启动竞态、非零退出、超时及 UI 竞态测试 |
| Debug | 断点、暂停/继续/单步、线程/栈/变量/求值 API 与基础请求面板 | 实际断点命中、栈、变量、求值、单步与继续；完整树形 UI、断点持久化和 verified 事件更新待后续 |
| 热更新 | 手动 hotReload / hotRestart | 实际 Debug 样例、编译失败保留原会话测试；自动保存监听未实现 |
| 日志 | 10000 行 / 4 MiB 核心上限、分页搜索、批量通知、可见窗口复制 | Rust、UI、事件积压恢复；完整轮转文件与导出待后续 |
| 源码 | 只读、行号、可见行构建，1 MiB 文件 / 源码视图最多2000行 | 实际 FFI Unicode 与分页测试；高亮/暂停位置/断点行操作待后续 |
| DevTools | 原生网络面板；匹配 SDK 的官方 Inspector / Performance / CPU / Memory / Logging，macOS WKWebView 实测 | Windows WebView2 已实现但未实机验收；Linux 内嵌未实现；详细验证及边界见 validation.md |
| 测试 / Preview / 工具 | 尚未实现 | 留在阶段二/三范围 |

Debug 面板依据模式、noDebug、状态和适配器 capabilities 开放；Profile/Release 关闭调试与热更新入口。SDK 的 Flutter 热更新扩展按当前验证基线开放，不推断其他 SDK 版本的支持。

## 尚待确定

三个平台最低宿主版本、额外目标 SDK 矩阵、Dart-Code 版本清单、Windows/Linux WebView、性能预算、默认外部编辑器和分发签名仍需原型及真实样例验收。当前不设未经测量的启动或内存预算，也不把应用包磁盘大小作为常驻内存。

macOS 为开发工具调用外部 SDK，release/debug entitlements 未开启 App Sandbox；发行签名、公证与安装验证尚未执行。Windows .bat 参数当前明确拒绝 shell 展开字符，带空格路径通过引号处理，仍需 Windows 真实路径样例验收。
