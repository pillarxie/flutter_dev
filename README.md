<div align="center">
  <img src="assets/branding/app-icon-256.png" width="96" alt="Flutter Dev 图标">
  <h1>Flutter Dev</h1>
  <p>为 Flutter 开发打造的独立运行与调试工作台。</p>
  <p>
    <a href="#快速开始">快速开始</a> ·
    <a href="docs/usage.md">使用指南</a> ·
    <a href="#参与贡献">参与贡献</a> ·
    <a href="https://github.com/pillarxie/flutter_dev/issues">问题反馈</a>
  </p>
</div>

Flutter Dev 将项目管理、设备选择、运行调试、网络请求和 DevTools 集中在一个桌面应用中。你可以继续使用喜欢的编辑器编写代码，在工作台中启动应用、查看日志、执行热重载和分析性能。

基于 **Flutter + Rust** 构建，面向 macOS、Windows 和 Linux。

![Flutter Dev 浅色工作台](docs/design/implemented-session-light.png)

<details>
<summary>查看深色工作台</summary>

![Flutter Dev 深色工作台](docs/design/implemented-session-dark.png)

</details>

*截图使用样例会话展示界面。*

## 功能特色

- **项目与 SDK 管理**：识别仓库中的 Flutter 应用，恢复项目列表，支持 FVM、项目独立 SDK 和全局默认 SDK。
- **运行与调试**：选择设备与运行模式，启动或附加应用，管理多个会话，执行热重载、热重启和基础断点调试。
- **日志与源码**：搜索、复制运行日志，浏览只读源码，发送调用栈、变量与表达式求值请求。
- **网络请求查看**：展示请求头、查询参数、表单和响应，支持 JSON 展开、原始内容切换与复制，无需添加 Dio 拦截器。
- **DevTools 集成**：在工作台中打开 Inspector、Performance、CPU Profiler、Memory 和 Logging。
- **构建与打包**：通过预设执行 Flutter 构建，查看构建日志并打开产物目录。
- **桌面体验**：浅色与深色主题、自适应窗口布局，以及持久保存的应用偏好。

## 平台支持

项目处于早期开发阶段，目前以 macOS 为主要开发和验证平台。

| 桌面平台 | 当前状态 |
| --- | --- |
| macOS | 已完成本机运行、调试和内嵌 DevTools 验证 |
| Windows | 已提供桌面工程；内嵌 DevTools 使用 WebView2，待实机验证 |
| Linux | 已提供桌面工程，待实机验证；DevTools 暂通过外部浏览器打开 |

可运行或构建的目标取决于宿主系统、项目所选 Flutter SDK 和本机工具链。例如，iOS 构建需要 macOS 与 Xcode。

## 快速开始

### 环境准备

| 工具 | 版本 |
| --- | --- |
| Flutter | 3.38.3（当前开发基线，包含 Dart 3.10.1） |
| Rust | 1.95.0 或更高版本 |

还需安装对应桌面平台的工具链：

- **macOS**：Xcode、命令行工具和 CocoaPods。
- **Windows**：Visual Studio 的 C++ 桌面开发组件，以及 NuGet CLI；内嵌 DevTools 需要 WebView2 Runtime。
- **Linux**：Clang、CMake、Ninja、GTK 3 开发库及 liblzma 开发库。

### 从源码运行

```sh
git clone https://github.com/pillarxie/flutter_dev.git
cd flutter_dev
flutter pub get
flutter run -d macos
```

在 Windows 或 Linux 上，将最后一行的 `macos` 替换为 `windows` 或 `linux`。Rust 核心会在 Flutter 构建过程中自动编译，无需单独启动服务。

### 开始使用

1. 点击「新增项目」，选择 Flutter 项目或包含多个应用的仓库。
2. 选择应用、设备、运行模式和入口，需要时在「高级设置」中指定 SDK 与启动参数。
3. 点击「启动会话」，通过会话页查看日志、热重载、调试和使用 DevTools。
4. 需要打包时，点击项目配置页的「构建」，选择预设并执行。

完整操作说明、网络面板支持范围及常见行为见 [使用指南](docs/usage.md)。

### 构建桌面应用

在对应宿主系统上执行：

```sh
flutter build macos --release
# Windows: flutter build windows --release
# Linux:   flutter build linux --release
```

macOS 构建产物为 `build/macos/Build/Products/Release/Flutter Dev.app`。当前源码构建尚未完成正式发行签名与公证。

## 开发路线

接下来重点完善：

- 源码断点交互、调用栈和变量树。
- 运行配置持久化与导入。
- 文件变更后的自动热重载。
- 测试发现、执行与结果展示。
- Windows / Linux 的实机兼容性与 Linux DevTools 内嵌。

目前的调试面板仍以基础协议请求为主；网络面板仅支持已连接 VM Service 的 Debug 会话中的 `dart:io` / `http_profile` HTTP 请求。更多平台与能力说明见 [兼容性说明](docs/compatibility-baseline.md)。

## 参与贡献

欢迎通过 [Issues](https://github.com/pillarxie/flutter_dev/issues) 反馈问题、提出想法，或提交 [Pull Request](https://github.com/pillarxie/flutter_dev/pulls) 改进功能与文档。

反馈问题时，请附上操作系统、Flutter / Rust 版本、复现步骤及相关日志。涉及较大功能或架构调整，建议先在 Issue 中讨论方案。

源码主要分为三部分：

| 目录 | 职责 |
| --- | --- |
| `lib/` | Flutter 工作台、界面组件与原生桥接适配 |
| `rust/` | SDK、协议、进程、会话、设置与构建管理 |
| `rust_builder/` | Rust 原生库的 Flutter 插件与构建接线 |

开发前请阅读 [开发指南](docs/development.md) 和 [AGENTS.md](AGENTS.md)，了解检查命令、桥接生成方式及项目约定。架构背景见 [技术设计](docs/technical-design.md)。

## 致谢

项目基于 Flutter、Rust、flutter_rust_bridge 和 cargokit 构建，并复用 Flutter SDK 提供的调试适配器与 DevTools。
