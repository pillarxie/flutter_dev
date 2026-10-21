# 开发指南

[返回项目首页](../README.md) · [协作约定](../AGENTS.md)

运行环境与源码启动步骤见项目首页。以下命令均在仓库根目录执行。

## 修改 Rust API

API 位于 `rust/src/api/core.rs`。桥接文件由官方生成器管理，请勿手写修改生成代码。

```sh
cargo install flutter_rust_bridge_codegen --version 2.12.0 --locked --root .tools
.tools/bin/flutter_rust_bridge_codegen generate
```

Windows 的可执行文件是 `.tools/bin/flutter_rust_bridge_codegen.exe`。Rust 和 Dart 桥接依赖、生成器版本必须一致。

## 验证

```sh
cargo fmt --manifest-path rust/Cargo.toml -- --check
cargo clippy --manifest-path rust/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path rust/Cargo.toml --locked
flutter analyze
flutter test
```

运行实际原生桥接测试时，先 `cargo build --manifest-path rust/Cargo.toml --lib --locked`，再设置 `FLUTTER_DEV_SETTINGS_PATH` 为专用测试文件，并通过 `--dart-define=FLUTTER_DEV_NATIVE_LIBRARY=/absolute/path/to/native/library` 指定动态库。测试会保存和清除该隔离设置文件，不使用个人应用设置。

macOS 示例（临时目录仅用于此次测试）：

```sh
cargo build --manifest-path rust/Cargo.toml --lib --locked
test_settings_dir=$(mktemp -d)
FLUTTER_DEV_SETTINGS_PATH="$test_settings_dir/settings.json" flutter test --dart-define="FLUTTER_DEV_NATIVE_LIBRARY=$PWD/rust/target/debug/libflutter_dev_core.dylib"
```

Windows / Linux 的动态库文件名分别为 `flutter_dev_core.dll` / `libflutter_dev_core.so`。未指定原生库时，普通 `flutter test` 会跳过需要实际 FFI 的用例。

真实 SDK 检查（会启动并清理测试拥有的 daemon）：

```sh
cargo run --manifest-path rust/Cargo.toml --example sdk_smoke -- /absolute/path/to/flutter
```

添加第二个参数 `/path/to/disposable/sample` 可进一步检查桌面 launch、DAP threads、热重载、热重启和停止。该检查会实际构建并启动这个样例，请使用专门的样例项目。第三个参数可指定持续执行位置的断点行号，额外检查断点、调用栈、变量、求值和单步。

同设备双项目日志隔离验收：创建两个不同 bundle ID 的可丢弃 iOS 样例，分别添加 `.flutter-dev-log-isolation-owned` 标记。入口读取 `const String.fromEnvironment('FLUTTER_DEV_LOG_MARKER')`，每秒打印 `$marker stdout $counter`、同一 print 内第二行 `$marker stdout multiline $counter`、`debugPrint('$marker debugPrint $counter')` 和 `stderr.writeln('$marker stderr $counter')`。再执行：

```sh
cargo run --manifest-path rust/Cargo.toml --locked --example session_logs_smoke -- /absolute/flutter/sdk /path/to/disposable/a /path/to/disposable/b IOS_DEVICE_ID
```

检查自动使用临时设置，给两个会话传不同 marker，验证各自 VM 地址及进程、持续输出分类和多行续行，并依次热重启再检查隔离；每个阶段持续观察10秒。失败、完成或 Ctrl+C 后清理此检查拥有的会话与 daemon，不操作个人业务项目或已有工作台进程。

真实 macOS DevTools WebView 集成测试（指定专用 Flutter 样例，不使用个人业务项目）：

```sh
FLUTTER_DEV_SETTINGS_PATH=/tmp/flutter-dev-devtools-test-settings.json flutter test integration_test/devtools_desktop_test.dart -d macos --dart-define=FLUTTER_DEV_SMOKE_SDK=/absolute/path/to/flutter --dart-define=FLUTTER_DEV_SMOKE_PROJECT=/path/to/disposable/sample
```

该检查通过真实 WKWebView 验证五个官方页面、VM WebSocket 数据、Inspector 扩展与内存数据；完成或失败时清理测试拥有的会话和服务。可选 `FLUTTER_DEV_SMOKE_ARTIFACT_DIR` dart define 为截图输出目录。不指定 SDK/样例时，该集成测试跳过；普通 `flutter test` 仍执行协议投影与界面回归。

CI 已配置三个宿主的核心测试、Flutter 测试和 release 构建。配置存在不代表远端执行已通过；验证证据、版本矩阵与未完成项分别记录在 [兼容基线](compatibility-baseline.md) 和 [验收记录](validation.md)。


本轮工作台效率功能的 macOS 实际 FFI / Flutter 测试运行器验收可单独执行：

```sh
cargo build --manifest-path rust/Cargo.toml --lib --locked
test_settings_dir=$(mktemp -d)
FLUTTER_DEV_SETTINGS_PATH="$test_settings_dir/settings.json" flutter test test/productivity_native_test.dart \
  --dart-define="FLUTTER_DEV_NATIVE_LIBRARY=$PWD/rust/target/debug/libflutter_dev_core.dylib" \
  --dart-define="FLUTTER_DEV_SMOKE_SDK=/absolute/flutter/sdk"
```

该测试创建可丢弃 Flutter 样例及编辑器参数捕获脚本，执行真实测试失败和精确重跑，不启动个人编辑器、不操作用户工程。未同时指定 SDK、原生库或不在 macOS 时跳过；其他 FFI 测试仍按前文单独设置隔离路径执行。自动热重载的去抖和能力竞态在 Rust 临时文件 / 假 DAP 用例中执行；真实 macOS 保存链路另通过下面的受保护样例模式验证，仍不能等同于用户业务应用回归。


自动热重载实机样例模式：仅对命名为 `flutter_dev_productivity_smoke`、根目录有 `.flutter-dev-smoke-owned` 标记文件的可丢弃项目开放；必须设置测试专用 `FLUTTER_DEV_SETTINGS_PATH`。样例的 State.reassemble 调用 `debugPrint('auto-smoke-marker-1')`。检查会修改该标记为2、确认自动重载后应用输出变化，再关闭自动监控、修改为3并验证未自动执行，最后执行手动热重载、热重启及停止。不要用于业务项目。

```sh
FLUTTER_DEV_SETTINGS_PATH=/tmp/flutter-dev-auto-reload-smoke-settings.json cargo run --manifest-path rust/Cargo.toml --locked --example sdk_smoke -- /absolute/flutter/sdk /path/to/disposable/flutter_dev_productivity_smoke --auto-reload
```

目录外本地依赖验收使用 `--auto-reload-dependencies`。应用保持上述包名和所有权标记；在应用目录旁创建名为 `flutter_dev_smoke_dependency` 的纯 Dart 包，其 `pubspec.yaml` 的 `name` 也必须是 `flutter_dev_smoke_dependency`，根目录同样放置 `.flutter-dev-smoke-owned`。依赖的 `lib/marker.dart` 内容为 `String dependencyMarker() => 'dependency-smoke-marker-1';`；应用通过 `path: ../flutter_dev_smoke_dependency` 引入并执行 `flutter pub get`，在 `State.reassemble()` 中同时输出应用标记及 `debugPrint(dependencyMarker())`。该模式先等待 Rust 监控初始化，再依次修改应用和目录外依赖源码，检查真实 reassemble 输出及恰好两次自动重载；关闭开关后再修改两处，确认均不自动触发，随后验证手动热重载读取最新代码、热重启和停止。固定目录、包名和所有权标记用于限制可写范围，不会遍历并修改任意本地依赖。

```sh
FLUTTER_DEV_SETTINGS_PATH=/path/to/disposable/settings.json cargo run --manifest-path rust/Cargo.toml --locked --example sdk_smoke -- /absolute/flutter/sdk /path/to/disposable/app --auto-reload-dependencies
```

两次自动保存检查均输出从保存到 reassemble 标记的耗时，并限制在 6 秒以内；初始化监控和手动操作仍允许 40 秒。正常轮询校验间隔为 8 秒，依赖保存后另等待 10 秒检查是否重复重载。受限执行沙箱可能静默屏蔽 macOS FSEvents，验证原生监听需在允许宿主文件事件的环境执行；仅在 8 秒或更久后观察到重载，只能证明轮询兜底工作，不能作为原生监听通过的证据。
