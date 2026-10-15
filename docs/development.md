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

真实 macOS DevTools WebView 集成测试（指定专用 Flutter 样例，不使用个人业务项目）：

```sh
FLUTTER_DEV_SETTINGS_PATH=/tmp/flutter-dev-devtools-test-settings.json flutter test integration_test/devtools_desktop_test.dart -d macos --dart-define=FLUTTER_DEV_SMOKE_SDK=/absolute/path/to/flutter --dart-define=FLUTTER_DEV_SMOKE_PROJECT=/path/to/disposable/sample
```

该检查通过真实 WKWebView 验证五个官方页面、VM WebSocket 数据、Inspector 扩展与内存数据；完成或失败时清理测试拥有的会话和服务。可选 `FLUTTER_DEV_SMOKE_ARTIFACT_DIR` dart define 为截图输出目录。不指定 SDK/样例时，该集成测试跳过；普通 `flutter test` 仍执行协议投影与界面回归。

CI 已配置三个宿主的核心测试、Flutter 测试和 release 构建。配置存在不代表远端执行已通过；验证证据、版本矩阵与未完成项分别记录在 [兼容基线](compatibility-baseline.md) 和 [验收记录](validation.md)。
