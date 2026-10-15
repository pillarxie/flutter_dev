# AGENTS.md

本文件适用于整个仓库。与用户协作、修改代码和维护文档时遵循以下约定。

## 协作规则

- 开始任务前先复述需求，确认已理解目标和范围；有影响实现的模糊点先向用户追问，明确后再开始。
- 中大型复杂任务优先拆分并派遣子进程或子代理，主线程尽量负责调度、集成和验收。按模块划定写入范围，避免多个代理同时修改同一文件。
- 需求不明确或代码定位耗时较大时，可以向用户反馈并寻求帮助。
- 保持实现简单、统一，不为封装而封装；优先复用已有模式和职责划分。
- 每次使用 plan 模式，用户确认 plan 后，将其写入 `docs/plan/`，文件名使用 `YYYY-MM-DD-主题.md`，再按确认后的计划执行。
- 修改前检查 `git status --short --branch`，保留用户已有改动；不覆盖、撤销或混入无关改动。
- 默认使用中文说明需求、进展和结果，代码标识符沿用现有英文风格。

## 项目与参考文档

Flutter Dev 是独立的 Flutter 桌面运行调试工作台。Flutter 负责界面，Rust 以应用内库管理 SDK、协议、会话、子进程、设置、构建及有界数据。

- `README.md`：当前能力、开发运行、使用说明和验证命令。
- `docs/technical-design.md`：架构与产品目标，包含尚未实施的内容。
- `docs/implementation-scope.md`：各阶段范围记录，旧段落不代表最新状态。
- `docs/compatibility-baseline.md`：工具版本、平台能力及已知限制。
- `docs/validation.md`：历史验收证据，不能当作本次重新执行的结果。
- `docs/design/prompts.md` 和 `docs/design/`：设计参考及实际控件预览。

以实际源码、测试和当前需求判断行为，区分设计目标、已实现功能和已验证结果。

## 代码职责

- `lib/features/`：工作台、设置、日志、调试、DevTools 和构建界面。
- `lib/core/presentation/`：展示模型、主题和共用控件；界面局部状态沿用 Flutter 已有方式。
- `lib/core/bridge/workbench_bridge.dart`：将原生 API 和事件转换为界面投影。
- `rust/src/api/core.rs`：公开的核心 API；`rust/src/protocol/`：daemon / DAP 协议。
- `rust/src/` 其他模块：SDK、进程、设备、会话、日志、设置、DevTools 和构建的实际管理。
- `rust_builder/`：Flutter 原生插件和 cargokit 接线；其中 cargokit 为随项目交付的构建工具代码，通常不改。
- `macos/`、`windows/`、`linux/`：桌面宿主；构建 Android/iOS/Web 目标的功能不表示本工作台具有这些宿主。

## 架构约束

- Rust 是唯一权威会话状态。Flutter 只保留选择、草稿、滚动位置及核心事件的展示投影，不增加另一套会话状态机。
- 会话事件按 sessionId、generation 和 sequence 隔离，忽略旧会话或迟到结果；后台事件不抢占当前选择。
- 运行和附加通过所选 SDK 的 DAP 执行。核心不得再额外启动一份 `flutter run`。
- SDK、daemon、DAP 和 DevTools 与当前会话匹配；更改全局 SDK 不修改已有会话使用的 SDK。
- 仅清理本工具或测试拥有的进程树；attach 默认解除附加并保留外部应用，不按进程名批量终止 Flutter/Dart。
- 日志、网络正文、源码和协议消息保持已有容量限制；分页或按需加载，不在两端长期复制全量数据。
- Debug、Profile、Release 及 noDebug 能力按实际模式与适配器能力开放。
- 设置由 Rust 校验并持久化，保留原子写入、串行化和保存失败反馈。
- 参数使用有类型数据和参数数组，避免拼接 shell 命令；保留 Windows 路径及脚本参数处理。
- UI 遵循既有主题、共用控件和深浅色风格，涉及布局时检查 560px 窄窗口。

## 工具与桥接生成

当前项目基线为 Flutter 3.38.3 / Dart 3.10.1、Rust 1.95.0、flutter_rust_bridge 2.12.0。具体约束见 `pubspec.yaml`、`rust/Cargo.toml` 和 CI。Rust、Dart 桥接依赖与生成器必须同版。

从仓库根目录执行：

```sh
flutter pub get
flutter run -d macos
```

Windows / Linux 使用对应宿主的 `-d windows` / `-d linux`。cargokit 在 Flutter 构建时编译并打包 Rust 原生库。

修改公开 Rust API 后运行官方生成器，并提交两端生成结果：

```sh
cargo install flutter_rust_bridge_codegen --version 2.12.0 --locked --root .tools
.tools/bin/flutter_rust_bridge_codegen generate
```

Windows 使用 `.tools/bin/flutter_rust_bridge_codegen.exe`。不手写修改 `lib/core/bridge/generated/` 和 `rust/src/frb_generated.rs`；配置位于 `flutter_rust_bridge.yaml`。

## 验证要求

按改动范围运行有意义的检查。仅文档修改检查链接、命令和 `git diff --check`；Rust、Flutter、桥接或宿主改动执行对应检查，跨层修改覆盖调用链。

```sh
cargo fmt --manifest-path rust/Cargo.toml -- --check
cargo clippy --manifest-path rust/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path rust/Cargo.toml --locked
flutter analyze
flutter test
git diff --check
```

- 实际 FFI 测试先构建原生库，通过 `--dart-define=FLUTTER_DEV_NATIVE_LIBRARY=绝对路径` 加载，并设置 `FLUTTER_DEV_SETTINGS_PATH` 为此次测试专用文件。具体命令见 README。
- 真实 SDK、launch、网络及 DevTools 集成测试使用可丢弃样例项目和测试拥有的进程，不操作用户业务工程或个人应用设置。
- 修改界面时验证深浅色、窄窗口、加载/失败状态、异步迟到结果和离开页面时的资源释放；复用现有测试和预览方式。
- 宿主或打包改动在对应平台执行 release 构建。macOS 构建不能证明 Windows/Linux 已通过。
- `.github/workflows/desktop.yml` 配置三平台检查；配置存在、提交成功和远端 CI 通过是不同结果。
- 最终报告区分本次通过的检查、跳过项、已知基线问题和未实机验证的内容。新增能力或限制同步 README，实际验收证据更新 `docs/validation.md`。

## 提交范围

- 提交源码、桥接生成代码、资源、文档、宿主工程和已有依赖锁文件。
- 不提交 `build/`、`rust/target/`、`.dart_tool/`、`.tools/`、Pods、临时测试设置、个人 IDE 状态或凭据。
- 提交前检查暂存列表与差异，避免将本机绝对路径或构建产物带入仓库。
