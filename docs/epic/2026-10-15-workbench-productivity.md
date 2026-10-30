# 工作台日常开发效率增强

日期：2026-10-15。用户授权实现前一轮提出的六项功能，沿用已有 Flutter 展示 / Rust 权威状态架构。

## 功能与验收边界

1. 运行配置：按项目持久化多套命名配置，覆盖设备、模式、入口、Flavor、环境变量及启动参数。切换项目不会串用草稿，重启后恢复；设置校验、原子写入及失败反馈由 Rust 负责。
2. 自动热重载：项目可启用保存 Dart 文件后热重载；连续变更防抖。仅对支持 reload 的 debug 会话生效，保持会话 SDK 与 generation 隔离；繁忙时合并请求，不并发启动另一个 flutter run；监控资源随会话销毁。
3. 网络：复制 cURL，按方法及状态筛选，响应正文搜索，JSON 全部展开 / 收起。继续保留节点折叠与原始正文复制；大正文沿用既有容量限制；搜索 / 筛选为展示状态，不复制全量网络数据。
4. 日志：识别堆栈源位置并使用已配置编辑器打开；日志整行仍可选择复制；支持错误筛选以及明确的暂停 / 恢复跟随输出。分页读取有界，筛选时继续读取后续页；切换会话与异步迟到结果不得混入。
5. 快捷键：启动、停止、热重载、热重启、搜索、快速切换项目 / 会话；遵循当前会话能力；文本编辑时避免截获普通输入；界面提供快捷键提示。
6. 测试：展示项目实际 test 文件树；运行全部、单文件以及从机器事件发现的单个测试；显示通过 / 失败 / 跳过计数、错误详情与输出，支持取消及失败重跑。Rust 使用所选 SDK 启动 flutter test --machine，以快照为唯一权威；关闭面板不终止测试，重开恢复最近任务。无测试项目明确显示空态，不伪造测试名称。

## 技术方案

- `lib/core/presentation/workbench_models.dart` 定义运行配置和测试展示数据，桥接接口提供必要操作；`lib/core/bridge/workbench_bridge.dart` 转换原生数据。
- Rust 管理配置校验持久化、文件监控 / 自动 reload 生命周期、测试进程与有界日志。进程仅清理本工具拥有的进程树，参数采用数组，编辑器打开不拼接 shell。
- Flutter 工作台提供配置、快捷键和测试入口；日志及网络面板保留局部选择与滚动状态；测试面板用轮询快照恢复任务且做项目 / revision 隔离。
- 保持组件简单，复用当前主题与已有选择控件；340px 内容宽度（560px 整窗）、深浅色、加载、失败与重试都需覆盖。

## 实现步骤及关键文件

1. 运行配置与自动重载：`rust/src/settings.rs`、`rust/src/session.rs`、`rust/src/api/core.rs`、桥接生成代码、`workbench_models.dart`、`workbench_bridge.dart`、`lib/features/workbench/workbench.dart`。
2. 网络增强：`lib/features/devtools/network_panel.dart`、`network_request_details.dart`、`network_payload_tree.dart` 与对应组件测试。
3. 日志增强：`lib/features/logs/log_panel.dart`、核心编辑器打开 API；补充定位解析、分页筛选、异步隔离和窄窗组件测试。
4. 测试管理：Rust 测试模块与公开 API；`lib/features/testing/test_panel.dart`；工作台入口；真实机器协议解析和 FakeBridge 组件测试。
5. 集成快捷键，更新 README / usage；执行针对性检查、Rust fmt / clippy / test、Flutter analyze / test 和 diff check。公开 API 修改后运行 2.12.0 官方桥接生成器。
6. 代码审查修复，更新 `docs/validation.md` 记录本次实际证据。按当前授权重新构建 macOS release 时，明确标注其他平台未实机验证。

## 验证重点

- 持久化恢复、失败反馈、项目隔离；防抖热重载与不可用模式；事件 generation / sequence 隔离。
- cURL 特殊字符安全、网络筛选 / 搜索 / JSON 收起后复制不变。
- 日志源位置不误匹配 URL；错误筛选跨分页且内存有界；切换会话旧读取及旧打开错误不污染当前页面。
- 测试机器事件映射到真实测试、失败重跑精确名称、取消与关闭后重连、无测试与无 SDK 失败状态。
- UI 深浅色与窄窗无溢出；离开页面释放计时器、订阅与控制器。
