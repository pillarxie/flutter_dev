# Flutter Dev 独立运行调试工具技术方案

日期：2026年10月13日  
技术方向：Flutter Desktop 界面与 Rust 核心  
交付顺序：优先 macOS，架构和构建从第一阶段覆盖 Windows 与 Linux

Flutter Dev 是可以脱离编辑器使用的 Flutter 桌面运行调试工具。用户在外部编辑器中修改代码，在本应用中选择项目、运行配置、平台和设备，完成启动、调试、热重载、测试和性能分析。

采用 Flutter Desktop 实现跨平台界面，Rust 管理协议、会话、子进程和数据缓冲，复用项目所选 Flutter SDK 的 daemon、调试适配器和 DevTools。产品目标是完整的运行调试体验，并以启动速度、常驻内存、持续运行稳定性和界面响应作为验收标准。

## 产品目标与范围

软件支持 macOS、Windows、Linux。macOS 是首个完整交付平台，其他平台从初期参与构建和核心验证。应用可运行的 Flutter 目标由宿主系统、项目配置和已安装工具链共同决定；跨平台宿主支持不代表任意宿主可以构建任意目标。

代码编辑、补全、重构和语言服务继续由外部编辑器承担。应用提供只读源码、断点操作、暂停位置展示和外部编辑器跳转，以保证调试流程可以独立完成。

“完整运行调试能力”以实施阶段选定的 Dart-Code 和 Flutter SDK 版本为验收基线。先建立功能清单和版本矩阵，逐项完成，避免将插件未来新增功能变成没有边界的承诺。

| 功能组 | 交付能力 |
| --- | --- |
| 项目与 SDK | 最近项目、多项目切换、单仓库多 Flutter 包、SDK 选择、FVM 项目路径、环境检查 |
| 运行配置 | 入口、工作目录、环境变量、Flavor、dart-define、工具参数、Debug/Profile/Release、运行而不调试 |
| 平台与设备 | 项目支持的平台、真机发现、设备上下线、模拟器列表与启动、设备状态与可用原因 |
| 会话 | 启动、停止、附加、解除附加、重跑、多会话管理、启动进度和错误恢复 |
| 调试 | 断点与条件断点、异常暂停、暂停与继续、单步、调用栈、isolate、变量、Watch、表达式求值；扩展能力按适配器声明开放 |
| 热更新 | 手动热重载、热重启、外部文件保存后自动热重载、编译错误展示 |
| 日志与源码 | 搜索、过滤、复制、导出、堆栈定位、只读源码、当前位置与断点展示 |
| DevTools | Inspector、布局调试、Performance、CPU、Memory、Network、Logging，与当前会话连接 |
| 调试开关 | Debug Paint、Performance Overlay、Repaint Rainbow、慢动画、基线绘制等所选 SDK 支持的服务扩展 |
| 测试 | 测试发现、选择执行、调试、取消、失败与跳过结果、重跑，以及 widget/integration test 的独立验证 |
| 辅助工具 | Doctor、Pub Get、Upgrade、Outdated、Clean、截图等项目或会话工具 |
| Widget Preview | 在支持的 SDK 中提供预览入口和会话管理，纳入版本能力矩阵 |

运行和调试能力不能按模式一律开放。Debug 承担完整调试；Profile 侧重性能分析；Release 提供运行、构建进度和可用日志。断点、热更新和 DevTools 页面还受具体目标平台限制，界面必须依据模式及实际能力展示。[Flutter 构建模式](https://docs.flutter.dev/testing/build-modes)、[Dart-Code 调试命令](https://dartcode.org/docs/debugging-commands/)

## 技术选择

### Flutter Desktop 界面

Flutter 官方支持 macOS、Windows、Linux 桌面应用。采用 Flutter 的控件、布局和开发工具建设设备选择、调试面板及配置界面；主界面不引入常驻网页前端。[Flutter 桌面支持](https://docs.flutter.dev/platform-integration/desktop)

发布软件使用 release 构建。软件自身的 Flutter 运行环境随发布包交付；被调试项目的 SDK 独立选择。用户切换项目 SDK 不需要重新编译本软件。

Flutter 引擎和 Dart 运行时构成基础资源开销。采用此方案不等于已经获得最低内存；性能验收覆盖整个宿主应用，不能只测 Rust 部分。

### Rust 核心

Rust 负责 SDK 定位、Flutter daemon 和 DAP 协议、会话状态、子进程管理、文件监听、日志缓冲与搜索。Flutter 只负责展示及界面交互，不再维护另一套权威会话状态。

首版将 Rust 作为应用内库加载，避免增加常驻后台服务。只有实际出现崩溃隔离或权限边界需求时，再考虑独立进程；应用内库也意味着核心异常可能影响整个宿主，必须做好错误处理和进程退出清理。

### Flutter 与 Rust 桥接

使用 flutter_rust_bridge 连接 Dart 和 Rust，支持异步命令及事件输出。桥接层只暴露产品需要的操作，保持简单，不为每个功能增加单独的服务层和包装层。[flutter_rust_bridge 文档](https://cjycode.com/flutter_rust_bridge/)

桥接传输以有类型的命令、事件和分页结果为主。日志批量传递，变量按展开请求，源码按文件及可见范围加载。避免逐条日志回调或双端长期保存全量输出。

### GPUI 的位置

GPUI 保留为性能对照方案，不作为首版同时维护的第二套界面。若 Flutter release 原型无法满足约定的性能预算，再用同样负载与 GPUI 对照，判断是否值得调整 UI 技术栈。GPUI 当前仍处于 pre-1.0，采用时需要考虑版本变更和控件集成成本。[GPUI 官方说明](https://github.com/zed-industries/zed/blob/main/crates/gpui/README.md)

## 架构与进程职责

调用链为：Flutter 界面 → Rust 核心 → 项目 Flutter SDK → 被调试应用。DevTools 使用当前会话的服务地址连接被调试应用。

| 部件 | 生命周期与职责 |
| --- | --- |
| Flutter 宿主与 Rust 库 | 随本软件运行；承载界面、配置、协议和会话状态 |
| flutter daemon | 按活跃 SDK 管理；发现设备、通知设备变化、查询和启动模拟器 |
| flutter debug-adapter | 每个会话一个；处理 launch/attach、调试请求和热更新 |
| flutter run 或 attach | 由 DAP 内部启动；外层不再启动第二份 |
| VM Service 与 DDS | 由 SDK 调试链路管理；提供运行时服务及 DevTools 连接 |
| DevTools 服务与 WebView | 用户打开对应工具时启动；与 SDK 和会话连接匹配 |

Flutter SDK 的 DAP 已负责调用 flutter run 或 flutter attach。Rust 发出 launch/attach 请求，不应同时自己再执行 flutter run。[Flutter DAP 说明](https://github.com/flutter/flutter/blob/master/packages/flutter_tools/lib/src/debug_adapters/README.md)、[Flutter adapter 实现](https://github.com/flutter/flutter/blob/master/packages/flutter_tools/lib/src/debug_adapters/flutter_adapter.dart)

设备 daemon 使用按行封装的 JSON 消息；DAP 使用带 Content-Length 的报文。两个解析器分开实现，按字节处理粘包、拆包和正文长度，并持续消费标准输出及标准错误。

UI 与核心交互至少包含以下操作：列出项目与设备、解析配置、启动、附加、停止、解除附加、热重载、热重启、设置断点、继续、单步、读取变量、求值、读取日志和打开 DevTools。会话变化通过统一事件流通知界面。

## 会话状态与所有权

会话状态采用统一模型：准备、启动中、运行中、暂停、停止中、已结束、失败。热重载和热重启作为当前会话上的操作状态处理，避免创建另一套运行状态。

Rust 保存 sessionId、会话代次、所选 SDK、项目、设备、配置和进程所有权。事件携带 sessionId、代次及序号，界面忽略上一次运行遗留的事件。Flutter 保存选中项、滚动位置和树节点展开状态等展示数据。

启动中的取消、设备断开、编译失败、适配器异常和用户退出都必须收敛为明确的终态。失败展示原因和重试入口，不能留在无限加载状态。

应用自行 launch 的会话由应用负责停止和清理；attach 外部应用的会话默认解除附加，保留原应用运行。关闭窗口不应隐式终止会话；退出软件时提供清晰的会话退出行为，并回收本软件创建的进程。

进程清理需要覆盖 SDK 启动的构建子进程。正常退出先走协议，再对本软件拥有的进程采用超时终止；异常终止路径也要清理。不得根据进程名批量终止用户机器上的 Flutter 或 Dart 进程。

## 项目与启动配置

项目识别以 pubspec.yaml 和实际 Flutter 包为入口。单仓库中存在多个应用包时，由用户选择具体包，并使用该包的工作目录和入口，不默认把仓库根目录当成 Flutter 项目。

SDK 解析优先级为：项目显式选择 → 已识别的项目 FVM SDK → 兼容导入的项目 SDK 设置 → 应用设置中的全局默认 SDK → 环境自动发现。项目 SDK 路径、配置读取或版本探测异常时，自动使用有效的全局默认 SDK；界面显示实际使用路径与回退原因，不改写项目 FVM 或编辑器配置。项目与全局 SDK 都不可用时明确展示错误。

应用设置页首版仅提供全局默认 SDK 的配置、验证、保存与清除。该设置由 Rust 持久化，保存前严格验证 SDK；更改对后续检查和启动生效，已有会话保留原 SDK。快捷启动保留上次提交的项目 SDK 偏好，启动时重新解析，避免记住旧的全局默认绝对路径。

记录实际 SDK 绝对路径与版本。同一个会话的 daemon、DAP、Dart 和 DevTools 均使用匹配的 SDK。[Dart-Code SDK 定位](https://dartcode.org/docs/sdk-locating/)

保存后的配置统一使用一份产品数据模型。Flutter 表单是编辑入口，Rust 负责校验和转成 SDK 参数；不同时维护表单参数、命令行字符串和另一套 launch 参数作为权威数据。

导入 .vscode/launch.json 时使用支持注释的 JSON 解析，并区分插件字段与 SDK DAP 参数。常见入口、工作目录、环境变量、deviceId、运行模式及工具参数进行显式映射。[Dart-Code 启动配置](https://dartcode.org/docs/launch-configuration/)

配置兼容按类别处理：

- workspaceFolder、环境变量和相对路径在核心解析。
- preLaunchTask、postDebugTask 和 compound 纳入任务与组合会话实现，不直接假定 SDK 认识这些字段。
- command 变量可能依赖其他 VS Code 扩展，需要对应替代实现或用户配置。
- 导入时显示支持、需要补充、无法转换的字段；禁止静默丢弃参数后仍称为完整兼容。

环境信息不能只来自终端 PATH。Finder、Dock、开始菜单启动均需验证绝对 SDK 路径、环境变量和工具链发现。命令通过参数数组构造，明确处理 Windows 启动脚本和带空格路径。

macOS SDK 子进程统一保留继承 PATH 的查找顺序，并追加已安装 Homebrew 的 bin、sbin 和 Ruby 工具目录，覆盖 GUI 启动时缺少 Homebrew 环境的场景。运行配置显式设置 PATH 时按原值使用，其他显式环境变量同样优先。不读取登录 shell 配置，不修改宿主应用的全局环境，也不替用户安装工具。

## 设备与运行调试

设备选择同时展示平台和具体目标，例如 iOS 与对应真机/模拟器、Android 与对应设备，以及当前可用的桌面和浏览器目标。设备状态包括可运行、未启动、连接中、不可用及原因。

Rust 对接 flutter daemon 的设备和模拟器接口。启动模拟器后等待设备可用事件，再交给 DAP launch；不能把“启动模拟器命令成功”当作“设备已经可运行”。活跃项目使用不同 SDK 时，按 SDK 管理 daemon，避免设备结果来自错误工具链。[Flutter daemon 协议](https://github.com/flutter/flutter/blob/master/packages/flutter_tools/doc/daemon.md)

每个调试会话使用 flutter debug-adapter。根据适配器 capabilities 开放断点、条件断点、表达式求值和其他可选功能。Flutter 的 hotReload/hotRestart 扩展用于手动及保存后的热更新。[Flutter DAP 扩展](https://github.com/flutter/flutter/blob/master/packages/flutter_tools/lib/src/debug_adapters/README.md)

外部编辑器保存后，由 Rust 监听磁盘变化，合并连续写入，过滤不参与应用编译的构建缓存和工具输出，并串行处理热更新。实际参与编译的生成源码变化必须保留，例如 build_runner 写入的 .g.dart 和 .freezed.dart。正在编译时合并后续修改；失败后保留原会话并展示错误。原生代码或其他不能热更新的变更提供重新启动入口。

断点由本软件持久化管理，跟踪适配器返回的 verified 状态和实际位置。外部编辑器断点不会自动导入或同步。源码修改、文件删除、热重启和 SDK 库断点都需处理，并防止把磁盘新源码误显示为暂停时的旧运行版本。

## 界面与交互

工作台采用左右分栏。左栏顶部提供新增项目入口，通过弹窗选择目录及 Flutter 应用包；项目列表下以二级条目显示该项目历史会话。项目行右侧提供快捷启动入口，复用该项目上一次提交的启动配置。

点击项目行时，右栏显示启动配置，包括 SDK 路径、平台、设备、运行模式、入口及其他运行参数。配置草稿按项目分别保留，尚未提交的修改不影响快捷启动使用的上次配置。点击历史会话时，右栏显示所选会话的日志、源码调试、Inspector、性能分析和测试功能区，右栏顶部右侧放置暂停、热重启、热重载及停止操作。

项目与会话选择属于展示状态，后台会话事件不改变当前选择。底部显示当前 SDK、设备连接与会话状态。失败信息就近展示原因及可执行的恢复操作。

源码视图承担只读浏览、语法高亮、行号、断点和暂停位置，不扩展成完整编辑器。源文件路径和行列信息可交给用户配置的外部编辑器打开。

日志、变量和源码页面只按需构建可见内容。状态变化局部更新，避免一次日志事件刷新整个工作台。简单界面状态使用 Flutter 标准的局部状态工具，核心事件通过统一适配进入展示层，不先引入多套状态管理方案。[Flutter 性能最佳实践](https://docs.flutter.dev/perf/best-practices)

快捷键、菜单、文本选择、复制、中文输入、缩放、高 DPI、窗口恢复和无障碍访问需要分别在三个宿主平台验收。

## DevTools 与测试集成

### DevTools

当前原生网络面板通过会话现有 DAP `callService` 访问 VM Service，Rust 仅开放 isolate 发现和 HTTP profiling 所需方法。Flutter 按可见页面获取增量请求列表，按需获取选中请求正文，按会话、代次及 isolate 隔离结果。Query / URL 编码表单保留重复字段并仅解码一层；JSON 缩进展示，原始内容可切换和复制。第一版仅开放已连接且启用调试的 Debug 会话，列表上限500条，正文预览上限128 KiB。该面板不依赖 WebView；Inspector、Performance、CPU、Memory、Logging 已按下述方案内嵌。

复用所选 SDK 的 DevTools，通过 DAP 返回的服务 URI 连接当前会话。重新启动后更新连接地址和 token；切换会话时重新绑定，不把第一次运行的 URL 永久保存。[Dart DAP 扩展协议](https://github.com/dart-lang/sdk/blob/main/third_party/pkg/dap/tool/README.md)、[DevTools CLI](https://docs.flutter.dev/tools/devtools/cli)

用户首次选择官方模块时再启动 DevTools 服务及 WebView。Rust `DevToolsManager` 使用当前会话 SDK 的 `dart devtools --machine --no-launch-browser --port=0 --host=127.0.0.1`，按会话管理 owned process，验证就绪事件、超时和存活状态。URL 使用官方单页嵌入模式、模块路径、当前服务 URI 和 `compiler=js`，避免 WKWebView 的 WasmGC 兼容问题。首次加载提供进度，失败提供重试。模块切换复用服务与 WebView，切回网络或离开面板即释放，停止/失败/退出时 Rust 兜底关闭。跨界面实例的串行打开/关闭避免旧面板迟到释放新服务；视图销毁不等于 WebView 后台进程已立即退出，实际内存回收趋势仍需要测量。

当前选用稳定版 `flutter_inappwebview` 6.1.5，以 WKWebView / WebView2 支持 macOS / Windows；Windows 初始化先检查运行库，构建需要 NuGet CLI。Linux 暂无本项目选定的稳定内嵌实现，显式提示不可用而不计完成。macOS 已验证本地页面、VM WebSocket、Inspector 与内存数据及各模块渲染；Windows、导入导出、完整快捷键/交互和 WebView 内存回收测量继续验收。[插件支持与安装要求](https://pub.dev/packages/flutter_inappwebview/versions/6.1.5)

当前 macOS 内嵌下载/导出未接管：稳定版插件的 WKDownload 目的地址回调取消默认下载。模块栏始终提供浏览器兼容入口，导出暂在浏览器完成；后续文件桥接需要单独覆盖 blob 文件、保存路径、取消和资源释放，不将页面渲染验收等同于完整导出验收。

外部浏览器作为兼容性恢复入口，不作为完成应用内集成的验收替代。为避免调试控制冲突，软件自身的 DAP 面板负责断点、单步和变量；DevTools 主要承担 Inspector 与性能工具。若同时开放 DevTools Debugger，需要显式处理其暂停与断点变化，不能预设它和 DAP 状态完全同步。

Widget Preview 使用支持该功能的 SDK 提供的预览服务，按项目管理，分别验证启动、重新连接和关闭；不直接绑定本软件 Flutter 构建版本。[Widget Preview 文档](https://docs.flutter.dev/tools/widget-previewer)

### 测试

测试发现、执行结果和断点调试是三个独立环节。结果树要区分等待、运行、通过、失败、跳过与取消，并支持文件、测试组和单项重跑。源码识别与运行后发现采用单独的适配策略，不能只把测试 stdout 放进日志页就视为完成。

测试调试使用 flutter debug-adapter --test，并消费 dart.testNotification。widget test、设备上的测试和 integration test 使用各自运行配置与验收路径；普通应用的 attach 流程不能直接套用到所有测试。[Flutter DAP 测试接口](https://github.com/flutter/flutter/blob/master/packages/flutter_tools/lib/src/debug_adapters/README.md)、[Dart 测试通知](https://github.com/dart-lang/sdk/blob/main/third_party/pkg/dap/tool/README.md)

## 性能设计与验收

首轮原型测量后确定启动、空闲内存、日志处理及界面响应的预算。预算写入验收记录并作为后续变更的约束，不以未经测量的 MB 或毫秒数宣称方案已经达标。

资源设计遵循以下规则：

- 日志缓冲同时设行数与字节数上限，完整导出使用可轮转文件，不无限追加内存文本。
- DAP 待响应请求、变量结果和源码缓存都有清理及容量策略。
- 调试状态事件可靠有序传递；高频日志与进度批量输出，避免界面消费速度影响协议响应。
- Flutter 只保留展示所需的数据；Rust 与 Dart 不长期双份持有全部日志及变量树。
- 设备扫描、文件监听、网络连接和 DevTools 按项目、会话与页面需求启动。
- 关闭会话后取消监听、释放缓存并清理拥有的子进程；后台空闲时避免持续刷新。

在固定机器、系统、SDK、项目和设备条件下测试 release 包。界面帧耗时可用 profile 工具定位，最终启动、内存及交付结果用 release 包确认。

| 场景 | 核查指标 |
| --- | --- |
| 冷启动和热启动 | 首次可交互时间、启动峰值内存、SDK 扫描是否阻塞界面 |
| 无项目与设备监听 | 稳态内存、空闲 CPU、持续唤醒情况 |
| 日志持续输入 | 滚动响应、搜索延迟、缓冲上限、桥接开销 |
| 大源码与变量树 | 文件打开、行定位、展开分页、界面帧耗时 |
| 调试启动与运行 | 宿主新增占用、SDK 子进程占用、构建峰值 |
| 连续启停与附加 | 多轮后内存增长、资源释放、孤儿进程、误终止 |
| DevTools 打开关闭 | WebView 及服务占用、重新打开行为、资源回收趋势 |

内存统计分别列出宿主与 Rust 库、SDK 工具、被调试应用、模拟器和 WebView/浏览器组件，并与相同配置的 CLI 基线对比。使用各系统可解释的内存指标；共享页面可能使逐进程 RSS 相加失真，不能把单个 Rust 进程的内存当成软件全部占用。

## 项目结构

项目保持一个 Flutter 应用和一个 Rust 核心，先按职责划分目录，不创建大量 crate、通用插件框架或多层服务包装。

```text
flutter_dev/
  docs/
    technical-design.md
  lib/
    main.dart
    app.dart
    features/
      projects/
      devices/
      sessions/
      debugger/
      logs/
      devtools/
      tests/
    core/
      bridge/
      presentation/
  rust/
    Cargo.toml
    src/
      api/
      sdk.rs
      device.rs
      session.rs
      process.rs
      protocol/
      log.rs
      watch.rs
  macos/
  windows/
  linux/
```

上面是实施时的建议结构。桥接生成文件由工具管理；平台目录承担必要的宿主配置和原生集成。业务能力先在现有模块中实现，只有重复需求已经出现时才抽公共组件。

## 实施阶段与完成标准

### 阶段一 架构原型与兼容基线

建立 Flutter 与 Rust 最小骨架，配置三个平台的构建验证，优先在 macOS 完成 daemon、DAP、日志、断点、热重载和 DevTools 的纵向链路。

本阶段完成标准：

- 确定 Rust、Flutter、桥接工具和最低目标 SDK 版本，建立功能及版本矩阵。
- Finder 启动的 release 应用能识别普通 SDK 和 FVM SDK。
- 能启动模拟器、等待设备可用并运行项目，且只有一个 launch 入口。
- 断点、单步、变量、求值、热更新、停止正常；attach 结束后外部应用继续运行。
- Windows 和 Linux 骨架能构建运行，核心协议能接入各自 SDK。
- 完成三个平台 WebView 方案验证及基础资源测量，设定性能预算。

### 阶段二 完整运行调试体验

实现项目与配置管理、完整调试面板、源码视图、断点持久化、文件保存自动热重载、日志功能、多会话和 DevTools 联动。macOS 功能优先完成，同时持续验证其他平台。

本阶段完成标准：真实项目可从配置到运行、暂停、修改、热重载和停止连续操作；设备断开、编译失败、重启和取消均可恢复；外部编辑器跳转可用，性能预算不被突破。

### 阶段三 功能补齐与跨平台交付

补齐测试、辅助命令、任务和组合配置兼容、Widget Preview 及基线清单中的剩余能力，完成 Windows、Linux 交互与工具链适配。

每个平台都以真实安装包验收菜单、中文输入、文件路径、快捷键、工具链调用、DevTools 和进程清理。macOS 完成签名、公证及安装验证；Windows、Linux 采用各自选定的安装与分发形式。

### 阶段四 稳定性与资源优化

按版本和平台矩阵执行真实项目回归，覆盖重复启停、日志洪流、SDK 切换、网络连接和 DevTools 开关。针对测量结果优化，形成支持版本、已知限制和验收记录后发布。

完整范围按阶段逐步交付；启动器原型只能代表阶段一，不能作为完整运行调试软件的完成标志。

## 实施前需确定的参数

以下事项在架构原型阶段确定，不改变 Flutter Desktop 与 Rust 的主方向：

1. 最低 Flutter SDK 和三个宿主系统版本，以及首批需要支持的 SDK 范围。
2. Windows、Linux 的 DevTools WebView 实现和必要的运行时依赖。
3. 启动、空闲内存、日志吞吐和界面响应的预算及测量设备。
4. 首批真实项目、Flavor、FVM、多包仓库、测试和配置兼容样例。
5. 默认外部编辑器跳转方式、退出会话行为及各平台分发形式。

这些参数以原型结果和实际项目需求确定后，记录为项目基线，再进入完整功能实现。
