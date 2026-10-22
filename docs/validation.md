# 首个增量验收记录

日期：2026年10月13日。

## 首次入库检查（2026年10月15日）

本轮整理 README、添加项目级 AGENTS，并初始化 Git 以推送 GitHub。未修改功能源码。

- `flutter analyze` 无问题；`flutter test --reporter compact` 为103项通过、3项跳过（2项可选视觉预览、1项需指定原生库的 FFI）。本轮没有重新执行实际 FFI、真实 SDK 或桌面集成验收。
- Rust 格式与严格 clippy 检查通过。首次默认并行测试为63项通过、2项 DevTools 用例超时，均发生在测试假 SDK 启动记录的3秒等待阶段。
- 随后串行复测 DevTools 的7项测试全部通过；整套 `cargo test --manifest-path rust/Cargo.toml --locked -- --test-threads=1` 的65项全部通过。并行超时原因尚未确定，不将串行通过视作该问题已修复。
- README 和 AGENTS 的本地链接及空白检查通过。首次提交全量 `git diff --cached --check` 另报告既有技术设计文档两处 Markdown 硬换行空格，以及 cargokit LICENSE / README 的末尾空行；保留原文。
- 提交范围已排除构建缓存、工具安装目录、Pods 和本机 IDE 状态；本轮未重新构建 release，也未确认远端 CI 结果。

## 已完成检查

| 检查 | 结果 |
| --- | --- |
| Rust 核心测试 | 20 项通过；DAP/daemon 分片与长度、Unicode、SDK/FVM、项目扫描、日志容量、owned tree、初始化取消、attach disconnect、热更新失败、写入超时、模拟器就绪和 daemon 初始化失败清理 |
| Rust clippy | `--all-targets -- -D warnings` 通过 |
| Rust fmt | `cargo fmt -- --check` 通过 |
| Flutter analyze | 整个工程无问题 |
| Flutter tests | 8 项通过，包括7项工作台交互/竞态测试和1项加载实际 Rust 动态库的 FFI 测试 |
| 实际 FFI | 有类型项目与会话、Unicode 源码分页、带代次/序号的失败终态事件、取消订阅及清理 |
| macOS release | Flutter 与 Rust、cargokit、桌面插件编译链接通过；产物 `build/macos/Build/Products/Release/Flutter Dev.app` |
| release 桌面启动 | 实际启动构建产物；原生界面树确认进入工作台，Rust 核心加载成功 |
| 真实 SDK daemon | 绝对路径 Flutter 3.38.3 / Dart 3.10.1，实际发现 macOS、iOS 和 Chrome，返回4个模拟器，关闭测试创建的 daemon |
| 真实调试样例 | 独立临时 Flutter macOS 项目；launch、threads、断点命中、调用栈、变量、求值 1+1=2、单步、继续、hotReload、hotRestart、stop 全链路通过 |

真实调试命令：`cargo run --manifest-path rust/Cargo.toml --example sdk_smoke -- /absolute/sdk /path/to/disposable/sample 8`。第三个参数是样例中持续执行位置的断点行号；仅在指定时检查断点及单步。首次 setBreakpoints 返回 pending/verified=false，随后实际命中并暂停；不能将首次响应视为断点验证已完成。

Flutter build 输出的 `Flutter Assemble` Run Script 每次运行警告来自默认宿主脚手架，无构建失败。当前目录没有 Git 仓库，未执行 git diff --check，手写代码做了尾随空白检查。

## 验收边界

- Windows/Linux CI 已配置，但尚未提交并触发远端运行；未作宿主交互和安装包验收。
- 真实模拟器启动、真实外部 attach 后应用存活、Finder 启动环境、设备断开恢复、多个真实并行会话需继续验收。已有协议与组件测试不能替代这些真实场景。
- macOS 官方 DevTools 内嵌已在后续增量验证；Windows 实机、Linux 内嵌、WebView内存回收测量、自动热更新、测试发现与结果树、完整断点和源码交互、配置持久化与导入仍待完成。
- 未完成固定设备下的启动、内存、CPU、日志洪流和多轮启停测量；性能预算待建立。
- release 产物未签名公证为正式发行包，当前只能代表本机开发构建通过。

## 项目与会话两栏布局增量

按新增 UI 需求调整为固定左侧项目树、二级历史会话和右侧配置/会话功能区。新增项目使用弹窗；项目行快捷启动复用该项目上次提交的配置，配置草稿按项目隔离。所选会话右上角提供暂停/继续、热重启、热重载和停止。

本轮验证：完整 `flutter analyze` 无问题；21 项 Flutter 测试通过（20 项工作台测试和1项实际 FFI 测试）。覆盖新增项目去重、多项目草稿、最近提交配置复用、后台选择保持、迟到启动响应、真实线程 ID、SDK 编辑失效/解析排队、平台设备模式参数及同代会话日志隔离。560px 两栏布局、日志底栏及侧栏标题无溢出。

macOS release 已重新构建通过，构建产物路径保持不变；已运行的旧 release 实例需要重启后加载新布局。

项目配置、会话功能区、新增弹窗和窄窗口已使用组件测试实际渲染检查；预览使用样例数据和本机字体。Rust API 与进程核心本轮未修改，不将此前的真实调试链路测试当作本轮再次执行的结果。

## 应用设置与全局默认 SDK 增量

应用设置首版仅包含 SDK 配置：读取、目录选择、严格版本验证、保存规范路径、清除默认值。Rust 使用系统应用配置目录保存 JSON，通过临时文件原子替换；无效 SDK 不覆盖已保存值。

健康项目 SDK 保持优先；项目显式路径、FVM 或项目配置解析/版本探测异常时回退全局。没有项目 SDK 配置时，全局默认先于环境自动发现。界面保留项目输入偏好，显示本次实际路径和回退原因。快捷启动保留已提交的 SDK 选择方式，每次启动重新解析；更新全局值不影响已运行会话。

本轮 Rust 28 项测试、严格 clippy、格式检查通过；Flutter 31 项测试通过（20项原工作台、10项 SDK 设置/回退、1项扩展后的实际 FFI 测试）。原生测试使用隔离 `FLUTTER_DEV_SETTINGS_PATH`，实际检查 SDK 默认值规范化保存/读取/清除、错误保存保留旧值、健康项目优先、解析回退，以及会话回退后的真实 SDK 路径和 warning 日志。会话测试使用只实现版本探测的 SDK 协议样例，适配器退出为预期；不将它当作真实目标 launch 验收。

设置页涵盖 560px 窄窗口、读取/保存中离开页面、晚到保存刷新项目缓存、后台会话不抢设置页面、独立项目 SDK 与快捷启动偏好隔离。损坏的设置文件显示读取错误，并允许直接重设或清除。项目 SDK 和全局 SDK 都不可用时保留明确错误，不回退到未经选择的其他 SDK。

本轮完整 Dart 静态检查无问题，macOS release 重新构建通过；应用设置页在桌面和560px窗口完成组件渲染检查。

## macOS 子进程 Homebrew 环境修复

修复 `OwnedProcess::spawn` 的统一环境构造，SDK 版本探测、daemon、DAP 均适用。没有显式 PATH 时保留继承顺序并追加已安装 Homebrew 的 bin、sbin、opt/ruby/bin；支持有效自定义 HOMEBREW_PREFIX，路径缺失或为空时恢复系统基础路径。运行配置的显式 PATH/HOME/其他变量原样优先，Windows/Linux 的环境处理未改变。

本轮 Rust 全套35项测试、严格 clippy 和格式检查通过，新增7项环境测试包括 GUI 路径补全、顺序/去重/空格、基础路径、显式变量覆盖、父子继承及自定义前缀隐式接线。

真实验证使用已构建的 `environment_smoke`，将父进程 PATH 限定为 `/usr/bin:/bin:/usr/sbin:/sbin`。同一环境下，未经过修复的 `which pod` 找不到工具；修复后的 OwnedProcess 返回 `/opt/homebrew/bin/pod`，`pod --version` 为1.17.0、`brew --version` 为6.0.13，选定 Flutter 3.38.3 的 doctor 实际识别 CocoaPods 1.17.0。doctor 对其他工具链问题的非零退出不计为 CocoaPods 回归，通过专门识别 CocoaPods 的输出验证本项能力。

命令示例：先 `cargo build --manifest-path rust/Cargo.toml --example environment_smoke --locked`，再运行 `PATH=/usr/bin:/bin:/usr/sbin:/sbin rust/target/debug/examples/environment_smoke /absolute/path/to/flutter`。该诊断仅用于 macOS，不安装或修改 CocoaPods/Homebrew。

本轮未更改 Flutter 界面或桥接 API，不重复界面测试；macOS release 需要重启加载新 Rust 库。用户实际 iOS 工程的完整构建与设备启动未再次执行，此次验收范围是 Flutter 子进程正常发现 CocoaPods/Homebrew。

## Apple 风格界面与黑白主题

先使用内置 imagegen 生成浅色和深色设计图，再还原项目/历史会话侧栏、顶部调试操作、日志工具栏、配置分组、设置页和添加项目弹窗。色彩使用中性黑白灰与蓝色强调，统一细分隔线、圆角及中文字体回退。设计图、最终提示词和实际 Flutter 控件渲染预览位于 `docs/design`；渲染使用测试数据与系统字体，不代表真实目标应用已启动。

默认浅色，侧栏和应用设置均支持浅色/深色切换。主题写入既有设置 JSON，旧文件缺少主题字段时兼容浅色；主题和 SDK 保存共用原子写入与锁，互相保留字段。切换保留当前会话、配置草稿和 SDK/设备缓存；快速切换按提交顺序保存，失败恢复最近已保存主题，包括首次读取尚未完成的情况。主题保存遇到损坏设置文件会报错并保留原文件，SDK 页仍支持显式恢复。

完整 Flutter 40 项测试通过（9项外观、20项工作台、10项 SDK 设置、1项真实 FFI）；真实 FFI 使用隔离设置路径验证主题与 SDK 互不覆盖、非法主题拒绝。Rust 38 项测试、严格 clippy、格式检查通过，完整 Flutter analyze 无问题。浅色/深色与 560px 窄窗的项目、会话、设置及调试布局完成实际控件渲染检查，无溢出；macOS release 构建通过（52.3MB）。

## 项目配置页布局调整

启动按钮移到固定标题栏右侧，正文优先显示运行目标。SDK 配置和启动选项移到下方高级设置，首次默认折叠；展开状态与控制器按项目保留，折叠不会清空或忽略提交参数。SDK 检查按钮与路径输入同排位于右侧，窄窗显示带提示的图标按钮。设备选择、刷新设备和启动模拟器作为同一组，大窗口同排，窄窗将两个操作紧接在设备选择下方。SDK 自动解析、原有启动条件及设备刷新/模拟器启动流程保留。

完整 Flutter 47 项测试通过（新增7项配置页测试），完整 analyze 无问题。新增测试检查默认隐藏、标题栏按钮位置与滚动后保持、高级参数折叠/跨项目保留及实际提交、设备刷新与模拟器启动行为、浅色/深色在1400px与560px的控件相邻关系及无溢出。原生桥接测试使用隔离设置文件；本轮无 Rust 源码修改。实际配置页控件预览保存于 `docs/design/configuration-*-v2.png`，使用测试设备和系统字体，不代表真实 iOS 工程重新运行。macOS release 构建通过（52.3MB）。

## 紧凑下拉菜单

平台、模式、设备和调试请求选择统一使用 MenuAnchor，浮层位于输入框下方，采用圆角、细边框、柔和阴影与选中勾选。菜单宽度兼顾输入框和窗口边界，短列表随内容收缩，长列表限高320px并滚动；窄输入框省略前置图标，保留完整值文字。运行模式补充简短说明，设备显示类型图标与模拟器标识。模拟器操作菜单同步采用圆角浮层及紧凑行距。选择仍直接更新既有配置，不引入额外配置状态。

本轮完整 Flutter 54 项测试通过（新增7项选择器测试）；最后菜单尺寸收尾后，再次通过7项选择器测试和1项实际控件渲染检查，完整 analyze 无问题。覆盖选中标记、外部值更新、禁用/空列表、Esc与外部点击关闭、Tab/Enter/上下键、80项长列表滚动及黑白主题560px菜单边界；短菜单验证不会被最大高度撑满。浅色、深色及窄窗实际弹出效果保存于 `docs/design/select-*-v3.png`，使用测试数据与系统字体。本轮未改 Rust 代码，macOS release 最终构建通过（52.3MB）。

## 原生网络参数面板

DevTools 页接入原生 HTTP 请求列表和详情，通过现有 SDK DAP `callService` 访问 VM Service。只开放 isolate 发现、版本和 HTTP profiling 所需 RPC，并校验 Debug 会话、调试启用、连接及存活状态。Query 与 URL 编码表单按字段解码，重复字段保序，嵌套 JSON 缩进，原始内容可切换和复制；非法百分号或 UTF-8 编码保留可见原文。正文按内容类型处理，multipart 明示原始文本回退，二进制显示大小说明。页面列表上限500条、正文预览与复制上限128 KiB。

完整 Flutter 68 项测试通过（新增6项格式化、7项面板和1项完整工作台入口测试），实际 FFI 使用隔离设置文件并验证网络 API 生成桥接及错误返回；最终 analyze 无问题。覆盖中文、加号与百分号的一次解码、重复参数、嵌套 JSON、原始内容复制、暂停后的父组件更新、同 URI 热重启、旧会话迟到列表/详情、首次请求期间清空、错误重试和560px完整工作台。浅色/深色实际控件预览为 `docs/design/network-parameters-*.png`，使用样例网络记录和本机字体。

Rust 完整47项测试、严格 clippy 和格式检查通过。超过16 MiB的网络服务 DAP 响应按有界流式处理，只让该 RPC 返回错误，保留调试适配器；测试使用真实 SDK 的 `seq,type,body,command,request_seq,success` 字段顺序，验证17 MiB响应后仍能执行 threads且会话保持 Running。未知超限消息、错误 envelope 和 JSON 结构仍按协议故障处理。

真实验证使用 Flutter 3.38.3 / Dart 3.10.1 和本轮创建的临时 macOS 应用，应用定时向自建 loopback HTTP 服务提交中文 Query、表单和编码嵌套 JSON。通过正式核心 API读取 getVM / isolate / HTTP profile / 单条正文，核验原始编码查询参数、表单字节和200响应；最终协议修改后再次通过热重载、热重启、停止并清理测试拥有的会话与 daemon。命令：`cargo run --manifest-path rust/Cargo.toml --example sdk_smoke -- /absolute/sdk /path/to/disposable/network_sample --network`；样例应周期性 POST 到 `flutter-dev-network-smoke` 路径并携带该检查约定的查询和表单字段。

首版只支持 Debug 中可用的 `dart:io` / `http_profile` HTTP 请求。打开面板后才启用 profiling，暂停只暂停页面刷新，未补采 profiling 启用前的启动请求。Web、Profile、Release、WebSocket 消息、未接入 profiling 的原生库、官方 Inspector / Performance / Memory 内嵌和跨宿主实机验收仍未完成。真实网络采集与参数格式化分别通过 SDK 及控件测试，未将样例预览当作用户业务工程运行证明。

最终 macOS release 编译链接通过，产物 `build/macos/Build/Products/Release/Flutter Dev.app`（52.5MB）。本轮未自动重启用户已运行的工作台，旧实例需重启后加载更新。

## 官方 DevTools 模块接入

日期：2026年10月14日。新增 Inspector、Performance、CPU Profiler、Memory、Logging 内嵌模块，默认保留原生网络面板。使用当前会话所选 SDK 的 DevTools，首次选择官方模块才启动 Rust 拥有的服务；模块切换复用一个 WebView 和服务，离开页面、返回网络、会话停止/失败及退出应用时释放。打开/关闭跨面板实例串行处理，避免旧面板的迟到关闭影响同会话的新面板；会话地址、代次、热重启和模式变化重新绑定。Inspector 限 Debug，其他模块接受有服务地址的 Debug/Profile；Release 不开放。官方单页嵌入与 debugger 隐藏参数保持源码调试入口由现有 DAP 面板负责。

完整 Flutter 77 项测试通过（新增9项 DevTools/原生平台接口测试），包括真实 FFI 新 API 调用。覆盖懒启动、模块/会话切换、pending open 后快速关闭再打开同会话、结束/Release/Profile 状态、迟到响应、重连与重试、312px模块栏、原生旧模块/旧 VM 回调、取消加载错误、浅色/深色主题与保留 URI 编码。最后补上常驻浏览器兼容入口后，10项 DevTools/完整窄工作台定向测试再次通过；最终 analyze 无问题。Rust 全套54项测试、严格 clippy、格式检查通过；新增7项服务测试覆盖选定 SDK 启动参数、服务复用/恢复、管道洪流和就绪协议、关闭取消启动、过期地址、超时/退出清理、URI 编码及模式校验。

真实 macOS 集成使用 Flutter 3.38.3 / Dart 3.10.1 / DevTools 2.51.1 和本轮专用样例，在实际 WKWebView 中逐一加载五个模块。页面包含 Flutter 渲染视图，并通过真实 WebSocket 收到 getVM / getIsolate 响应；进一步核验 Inspector 扩展数据与 Memory profiling 数据。截图确认 Widget 树、性能帧图、CPU 录制入口、内存类表/图和样例运行时日志已显示。真实截图位于 `docs/design/official-devtools-*.png`，为样例及原生 WebView 实际结果，非概念设计图。此测试直接使用原生 WebView 承载官方页面，工作台的模块切换/主题/重连另由组件与平台接口测试覆盖；不将样例验收当作用户业务项目已回归。

命令见 README 的 `integration_test/devtools_desktop_test.dart` 段落。测试只启动与停止其拥有的样例会话、DevTools 和 SDK daemon，不重启用户已有工作台。首次连接与等待模块功能数据后的最终检查均通过；最终一次启动提示 `Failed to foreground app; open returned 1`，但实际原生页面渲染、VM数据和截图检查全部成功，不将该提示作为测试失败。构建中的 Swift 弃用/未使用变量警告来自稳定版 WebView 插件，编译链接通过。

最终 macOS release 已构建，`build/macos/Build/Products/Release/Flutter Dev.app`（58.2MB）；重启新构建后可使用。本轮 Windows WebView2 仅实现运行库检测和界面处理，未实机运行；Linux 内嵌明确未实现，不以浏览器恢复入口替代完成验收。Profile 真实目标、CPU/性能完整录制操作、键盘/文件导入、WebView后台内存回收趋势继续验收。当前 macOS 插件未接管页面生成文件的下载，内嵌文件导出暂不支持，使用模块栏的“在浏览器中打开”兼容入口；此限制已记录在 README。

## 网络详情刷新跳动修复

2026年10月14日。网络列表刷新时曾条件插入/移除2像素的顶部进度条，令选中详情的顶部位置与可用高度反复变化。修复为始终保留固定高度的进度区，刷新时只改变其内容；不改采集、请求排序或详情选择逻辑。

新增1100px与420px回归测试：在已滚动并切换原始内容的详情旁模拟延迟刷新与新增请求，检查刷新进行中和结束后的详情矩形、滚动偏移及原始内容状态均不变，完成请求不重复读取详情。修复前两个测试都精确复现顶部下移2像素，修复后通过。25项网络/DevTools相关测试和完整 analyze 通过；本轮没有 Rust/API 修改。

macOS release 已重新构建通过（58.2MB），旧工作台实例需重启新构建后加载此修复。

## 网络详情区标签布局

2026年10月14日。按“参数 / 请求头 / 响应”组织详情，地址、状态、耗时和响应大小固定在顶部；地址摘要省略 Query，完整原始 URL 仍可悬停查看和单独复制。参数与 Headers 采用紧凑名称—值两列，重复字段保序，嵌套 JSON 保留缩进。请求头标签只展示请求 Headers，响应标签包含正文与响应 Headers；原始/格式化切换及复制放在分区标题旁。各标签独立保留滚动位置，同一请求刷新保留当前标签和展示模式，沿用固定2像素进度区避免跳动。

完整 analyze 无问题，26项网络/DevTools/窄工作台定向测试通过。验证新增请求前后的详情尺寸、滚动位置与原始模式稳定，标签切换后滚动恢复、分区归属、重复 Headers 及完整原始 URL 复制。浅色/深色在1200px和420px窗口均完成实际控件渲染检查，未发现溢出；十二张预览保存于 `docs/design/network-details-*-v2.png`，使用样例记录及本机字体，临时预览测试已移除。本轮未改 Rust/API 或重新执行真实目标网络采集。

macOS release 构建通过，产物 `build/macos/Build/Products/Release/Flutter Dev.app`（58.2MB）。已运行的工作台需要重启新构建后加载新详情布局。


## 网络详情标签顺序与 payload 节点

2026年10月14日。标签调整为“请求头 / 参数 / 响应”，首次打开请求和切换请求均默认选中参数。请求正文中名为 payload 的表单字段、JSON 正文中的 payload 对象或数组以节点树展示：根节点及第一层容器默认展开，箭头控制对象和数组独立展开/收起；字段名与值采用紧凑同行布局，窄列自然换行。重复 payload 按字段位置区分，嵌套路径按 JSON Pointer 转义，节点状态在标签切换、原始视图切换和同请求更新后保留，新请求重置。折叠不改变原始/格式化复制内容，非法 JSON 与仅解码一层后仍非 JSON 的文本保持可见。

每棵树最多200个可见节点、12层，缩进最多36像素；超过限制明确提示，正文预览和复制仍遵守原有128 Ki上限。31项网络/DevTools/窄工作台定向测试通过，另1项预览渲染通过；新5项测试覆盖独立嵌套对象/数组、切换与更新后的节点状态、复制、重复 payload、异常与二次编码、特殊路径键、200节点边界及280px深层展示。浅色/深色在1200px和420px预览正常，图片位于 `docs/design/network-payload-*-v3.png`，临时预览测试已删除。

详情组件、节点树和新测试的定向 analyze 无问题。本轮没有修改 Rust/API。全项目 analyze 与 macOS release 首次尝试期间，工作区并行新增构建模块，曾出现 `generated/build.dart` 缺失及 Rust `AppSettings` 初始化缺少 `build_presets` 的错误；对应生成文件补齐后再次验证，编译错误消失，全项目 analyze 剩构建模块测试 `test/build_dialog_test.dart:21` 的2条继承字段提示（本轮未改该文件）。macOS release 重新构建通过，产物 `build/macos/Build/Products/Release/Flutter Dev.app`（59.0MB）；旧工作台实例需重启新构建后加载更新。本轮未覆盖或修复并行改动。

## 项目打包构建

2026年10月14日。选中项目的标题栏在“启动会话”右侧新增“构建”按钮，无需选择设备。构建窗口独立选择平台 / 产物类型，支持内置 Release 预设、自定义参数以及预设新增、编辑、删除。预设写入既有设置文件，兼容旧文件并保留 SDK / 主题；参数以字符串数组交给项目所选 Flutter SDK，不经 shell 拼接。构建期间显示分页日志和停止入口，关闭窗口前需完成或停止构建。Rust 负责进程树、同项目重复构建检查、取消和退出清理，日志及历史数量均有限界。

成功后根据实际 Built 日志、目标默认目录或自定义目录定位产物，在 Finder / 文件资源管理器 / Linux 文件管理器打开。`.app`、`.xcarchive` 等包目录打开父目录，避免直接启动应用。自定义目录仅指定成功后打开的位置，实际输出位置由目标支持的构建参数控制。打开失败保留构建成功状态与日志，并可手动重试；重试成功清理旧提示。终态仍读取剩余日志页，清尾期间禁止重复启动。

最终 `flutter analyze` 无问题，93 项普通 Flutter 测试通过，另 1 项真实 FFI 测试使用隔离设置路径通过。新增 8 项构建窗口测试与 1 项工作台入口测试，覆盖独立平台选择、预设校验和持久化、编辑/删除、失败重试、停止、成功后打开、尾页日志、短暂读取错误恢复及浅深色窄窗口。真实 FFI 覆盖新增 API 类型、Unicode 参数与预设、保存其他设置后保留预设、失败退出码及 stderr 日志。Rust 全套 62 项测试、严格 clippy、Rust / Dart 格式检查通过；新增构建与设置测试覆盖实际参数传递、输出目录映射、取消和退出清理、重复构建、日志边界、打开失败重试、旧配置迁移及保存体积限制。

使用专用临时 Flutter 项目和隔离设置文件，通过正式 Rust API 执行真实 Flutter 3.38.3 的 `flutter build bundle --debug`，最终状态为 succeeded，输出为样例的 `build/flutter_assets`，系统 `open` 成功且无打开错误。临时验证程序已删除，不使用用户业务工程或个人设置。Windows / Linux 的文件管理器及各移动平台真实打包未实机验证。

macOS Release 应用已重新构建通过：`build/macos/Build/Products/Release/Flutter Dev.app`（59.0MB）。当前运行的旧实例需重启新构建后加载功能。


## 导入项目持久化与启动恢复

2026年10月14日。原项目列表只存在 Workbench 内存，关闭后清空；现已将导入项目的名称、绝对路径、入口、平台及上次选择写入既有 AppSettings。新增项目和选择变动生成不可变快照，串行提交；Rust 共用设置写锁，读改写保留 SDK、主题及构建预设，并原子落盘到既有系统应用配置目录。兼容旧设置文件的缺省项目字段，按路径去重，最多500个项目，总设置文件上限1 MiB。目录不存在时保留条目，由既有 SDK 检查显示错误，不自动删项目或启动会话。旧版本已经丢失、未保存的列表无法迁移，需要重新导入一次；历史会话、运行配置草稿及最近启动参数仍未持久化。

首次读取完成前只保留本地更改，不写空覆盖旧配置；迟到读取合并当前导入项目并保留用户的新选择。读取或保存失败有独立错误提示和重试，保存失败不清空窗口中的项目；SDK 编辑器修复配置后自动重读项目。退出等待当前读取与写入队列，未保存成功时取消退出，成功后再清理会话。

完整 Flutter 101 项测试通过，包括7项新增项目恢复/失败/并发/退出测试及真实 FFI 测试；全项目 analyze 无问题。覆盖项目元数据与选择恢复、重建应用后保持、加载期间新导入、读取失败不覆盖、保存失败重试、快照有序与退出 flush、缺失目录保留；额外验证读取失败且有新项目、持续保存失败时取消退出。原设置错误测试限定设置页面断言，FakeBridge 保存后模拟真实配置恢复，其他工作台/主题/构建/DevTools测试全部通过。

Rust 完整65项测试、严格 clippy 与格式检查通过；设置专项10项覆盖旧配置迁移、完整元数据、项目与其他设置互相保留、无效路径/选择、500项与1 MiB界限、损坏配置保护。原生库重新构建，真实 FFI 使用专用临时 FLUTTER_DEV_SETTINGS_PATH，检查新接口序列化、包含中文的不存在目录、去重、元数据和选择落盘/重读、SDK/主题/构建预设互保及无效保存保留原值，没有修改个人配置。

macOS release 构建通过：`build/macos/Build/Products/Release/Flutter Dev.app`（59.2MB）。未自动重启用户已运行的旧版本；重启新构建并重新导入此前未保存的项目后，后续重启与应用包更新会恢复列表。

## 构建、应用设置、图标与窗口缩放

2026年10月14日。使用内置 imagegen 分别生成构建弹窗、应用设置页设计图及透明应用图标；最终提示词、设计图与八张实际浅深色/窄窗控件预览位于 `docs/design`。构建弹窗采用分组配置、命令预览与输出卡片，操作区固定，宽窗双列、窄窗单列。设置页使用可点击的浅深主题预览卡与 SDK 分组；既有加载、错误、重试、保存、清除和设置持久化语义保留。已有 SDK 路径不显示虚构验证状态。

新图标源图为1254×1254 RGBA，原样保存至 `assets/branding/app-icon-source.png`，仅缩放导出 macOS 七尺寸、Windows 七尺寸 ICO、Linux 内嵌资源与侧栏图标。透明通道、各尺寸及最终 macOS 包内 AppIcon.icns 引用已检查。Linux 图标通过 gresource 编译内嵌，资源生成与生成代码的 C++17 `-Wall -Werror` 语法检查通过；CMake 参数按完整参数引用，避免路径含字面双引号。

macOS 显式启用原生窗口缩放并使用560×500最小内容区；Windows 保留可缩放系统边框并按显示器 DPI 计算最小内容尺寸；Linux 显式允许缩放并设置最小视图尺寸。回归测试覆盖1000→560→1000跨断点时构建名称输入的内容和焦点保留，SDK 草稿在560×500与恢复窗口后的保留、主题切换及保存/清除入口可达。静态分析无问题，六个修改 Dart 文件格式检查通过；全量 Flutter 回归104项通过、3项条件跳过。最终审查移除额外命令复制入口后，构建/外观与实际渲染22项定向测试全部通过。

最终 macOS Release 构建通过，产物为 `build/macos/Build/Products/Release/Flutter Dev.app`（60.6MB）。Windows/Linux 未进行完整构建与实机验证；原生电脑控制工具在检查 macOS 窗口时超时，因此真实鼠标拖拽缩放尚未验收，窗口尺寸布局已通过控件测试。未改动 Rust/API，未重新执行目标项目的真实打包或修改个人 SDK 配置。

## 项目 Git 分支识别与切换

2026年10月15日。新增、恢复和选择项目时读取所属 Git 仓库，在侧栏显示当前分支，在项目配置页提供本地分支选择及刷新。支持普通 `.git` 目录、worktree 的 `.git` 文件和仓库子目录中的项目；非仓库隐藏分支控件，分离 HEAD 显示短提交号，无提交仓库显示当前分支及说明。分支信息实时读取，不写入持久化设置。

Rust 使用参数数组执行 Git，输出与执行时间有界，仅切换已有本地分支；不强制覆盖、自动 stash 或创建远程分支。禁用 checkout hooks/fsmonitor，并清除继承的索引、对象库和仓库路径等 Git 环境变量，防止操作其他索引或仓库。切换冲突显示原始错误并保留已知分支；读取失败可重试。同仓库项目同步切换和手动刷新结果，迟到读取不能覆盖更新的请求；成功切换后重新检查相关项目 SDK，已运行会话仍使用原有 SDK。

本次完整 Rust 75 项测试通过，严格 clippy 和格式检查通过；其中10项 Git 测试使用专用临时仓库，覆盖普通/子目录/非仓库、worktree及已占用分支、无提交、分离 HEAD、未提交文件冲突保留、远端分支拒绝、选项注入拒绝、hooks禁用、输出上限和继承环境污染。环境测试通过独立测试子进程注入其他仓库路径及替代索引，验证切换后真实索引与工作树一致、替代索引和外部仓库未变。

最终完整 Flutter 115 项测试通过，4项条件跳过（两项真实 FFI 和两项按需设计截图）；两项真实 FFI 已单独指定重新构建的动态库与隔离设置文件通过，包含新增 Git API 的 Unicode 分支、子目录识别、无提交仓库及错误参数调用。新增12项 Git 控件测试覆盖同步刷新、失败/重试、项目选择和销毁后的迟到结果、更新请求优先，以及浅深色1400×800和560×500布局。完整 analyze 无问题，修改的6个 Dart 源码/测试文件格式检查和 `git diff --check` 通过。另用实际控件生成浅深色宽/窄窗及菜单共8张临时截图并检查布局，无溢出；截图使用样例数据，不代表用户仓库实机操作已验收。Windows/Linux 尚未实机验证，未操作用户业务仓库或个人设置。

最终 macOS Release 构建通过：`build/macos/Build/Products/Release/Flutter Dev.app`（60.8MB）。末次异步请求保护修复后再次增量构建通过，产物包含最终代码；未自动重启已运行的旧实例，需退出并重新打开新应用包。

## 后台构建与任务详情入口

2026年10月15日。构建窗口在准备、运行和停止阶段均允许关闭，关闭只释放窗口轮询，不停止 Rust 拥有的构建进程。左侧固定“构建任务”入口显示进行中数量，支持跨项目查看本次运行内的近期任务；点击任务打开只读详情，重新分页读取日志，可停止任务或打开产物目录。原窗口关闭后，工作台只在有活跃任务时刷新有界快照，不读取后台日志；任务完成后停止自动轮询。历史沿用 Rust 的最多32条限制，不新增持久化历史或第二套任务状态。

新增官方桥接 API `list_builds`，从 Rust 读取按构建 ID 倒序的权威快照。工作台隔离启动前的迟到列表结果；启动请求尚未返回时关闭窗口，仍跟踪请求并接收任务。退出应用时确认后台任务，等待尚未返回的启动请求注册后再执行核心清理，并拒绝退出过程中新发起的构建，避免进程遗漏。

本次 `flutter analyze` 无问题，19项构建窗口 / 任务列表 / 完整工作台定向测试通过；全套 Flutter 测试126项通过，2项设计预览因默认未启用而跳过。全套运行加载新构建的原生库并使用专用临时设置文件，真实 FFI 新增验证已结束任务的列表、状态和退出码，以及 shutdown 后列表清空。Rust 全套76项测试、严格 clippy、Rust / Dart 格式和 `git diff --check` 通过。新增核心测试验证跨项目活跃/终态快照、数值排序和列表读取不持有日志锁。

界面回归覆盖关闭不停任务、迟到启动结果、关闭后跨项目重开详情和日志、后台完成后保留结果且停止轮询、停止/打开产物目录、刷新失败恢复、退出等待 pending start、过期列表不覆盖新任务、销毁后不再轮询，以及浅深色560px窄窗口。此次未重新执行真实 Flutter SDK 样例构建；Windows / Linux 未实机验证。工作区既有 Git 分支功能等未提交改动保留，不计作本次新增功能。

本次 macOS Release 编译链接通过，产物 `build/macos/Build/Products/Release/Flutter Dev.app`（60.9MB）。未重启用户正在运行的应用，新功能需重启新构建后加载。

## 参数和响应的 JSON 节点展开/收起

2026年10月15日。将原先仅用于请求 payload 字段的节点树扩展至任意 Query、表单字段、JSON 请求正文和 JSON 响应正文中的对象及数组。JSON 请求对象保留名称—值两列，根数组与响应正文使用整棵树；嵌套容器可独立展开/收起，空容器保留摘要。原始/格式化复制内容不受折叠影响；标签切换、原始视图切换和同请求刷新保留节点状态，切换请求重置。不同分区与重复字段的状态隔离，JSON 顶层字段标识编码，避免特殊字段名与嵌套路径碰撞。非法、截断 JSON 和标量内容继续显示为可选文本，沿用每棵树200个可见节点、12层及正文预览/复制上限。

本次完整 `flutter analyze --no-pub` 无问题；38项网络格式化、详情、面板、窄工作台及 DevTools 定向测试通过，包含新增7项交互测试。覆盖非 payload 字段、Query、JSON 请求与响应根数组、嵌套容器、分区状态隔离、特殊字段名、复制、刷新保留和请求重置，以及280px详情区的深浅色布局。另1项临时实际控件预览测试通过，检查720px与280px详情区的浅深色参数/响应共8张截图，节点缩进和换行无布局溢出；截图使用样例数据并保存在临时目录，临时预览测试已移除。本轮只修改 Flutter 展示层及相关测试/文档，未重新执行全套 Flutter、Rust、实际 FFI、真实目标网络采集或桌面打包验收。

## 网络请求列表清空入口

2026年10月15日。将搜索框右侧仅有垃圾桶图标的入口改为带“清空”文字的按钮，沿用既有本地清空逻辑：清空列表和选中详情，通过 VM 时间边界过滤旧记录与迟到结果，保留后续请求采集。使用指南同步标明入口位置。

本次12项网络面板/560px完整工作台定向测试通过，包括点击“清空”后计数归零、刷新不恢复旧请求、首次读取期间清空及迟到结果隔离；420px浅深色均验证按钮可点击且布局无异常。完整 analyze、修改文件 Dart 格式及 `git diff --check` 通过。未重新打包桌面应用或执行真实目标网络采集。

随后按用户要求重新执行 `flutter build macos --release`，构建成功，产物为 `build/macos/Build/Products/Release/Flutter Dev.app`（60.9MB），包含 JSON 节点交互和带文字的“清空”入口。已检查应用可执行文件及 `flutter_dev_core.framework` 已打入包内；未重启正在运行的应用，未将构建通过视为实机交互回归。

## 项目标题下的紧凑分支入口

2026年10月15日。移除项目标题下方的“启动配置”副标题和正文中的整块“Git 分支”卡片，在标题下以分支图标、分支名、下拉箭头及小型刷新按钮展示当前分支。分支行独立使用标题区可用宽度，窄窗口不受右侧启动/构建按钮挤压；长分支省略并可悬停查看，入口随标题固定。复用现有选择器菜单、键盘和焦点行为，默认表单选择器保持原样；切换、刷新、同仓库同步及迟到结果隔离逻辑未变。首次加载显示禁用的刷新进度图标，错误和无提交提示紧凑展示于正文路径下，非 Git 项目隐藏入口。README 和使用指南同步入口位置。

48项 Git、配置、通用选择器和工作台定向测试通过，另1项临时控件预览测试通过；完整 analyze、修改文件 Dart 格式及 `git diff --check` 通过。覆盖首次加载禁用、切换/读取失败重试、同仓库与迟到结果、游离 HEAD/无提交仓库，以及浅深色1400px和560px长分支菜单、刷新可点击和正文滚动后头部位置不变。已检查浅深色宽/窄窗及菜单共8张实际控件截图，分支行和菜单无布局溢出；截图保存在临时目录，使用样例数据，临时测试已移除。本轮未重新运行 Rust、实际 FFI、用户真实仓库分支操作或 Windows/Linux 实机验收。

本次 `flutter build macos --release --no-pub` 构建成功，更新后的应用包为 `build/macos/Build/Products/Release/Flutter Dev.app`（60.9MB），已检查主程序和 Rust 核心 framework 存在。未重启用户正在运行的旧实例。

## 六项日常开发效率增强

2026年10月15日。实现项目运行草稿、上次启动及多套命名配置持久化；原始环境变量/参数草稿保留，配置另存、更新、重命名、删除及跨项目隔离。Rust 串行校验并原子保存，Flutter 合并草稿保存并展示失败重试。自动热重载按项目保存开关、更新已有与新会话，Rust 有界扫描和去抖，复用 DAP 热更新，遵循模式和显式能力；页面离开不停止监控，会话终止清理。

网络新增方法/状态多选、请求右键按需复制 POSIX cURL、响应正文搜索及分区全部展开/收起。复制保留原始 URI、重复 Headers 和完整文本正文，拒绝不完整/二进制/超限内容；实际 HttpProfiler 顶层发送 endTime、无 Content-Type 时抑制 curl 默认表单头、引号及以 @ 开头正文均有回归。日志支持错误筛选、明确的暂停跟随、完整带空格 POSIX/Windows 路径与 package/file URI 定位，点击通过可配置编辑器参数数组打开，并保留日志原文选择复制。

工作台增加能力受限的启动/停止/热更新/搜索/项目会话切换快捷键和提示；页签使用 Cmd/Ctrl 数字，不截获 macOS Option 数字文本。测试页和独立项目入口使用真正的 flutter test --machine，支持文件发现、运行全部/文件/机器事件发现的单测试、精确失败重跑、停止、错误与尾日志读取、关闭后重连；核心管理进程及有界快照，退出保护待启动会话与测试。560px 下标题、分支与项目操作适当分行；通用选择器保留默认表单样式，紧凑入口左对齐。

本次最终全套 Flutter 183项通过、5项条件跳过（两项设计预览、原有两项 FFI、新增真实 SDK FFI）；使用最终重建原生库和各自专用临时设置文件，另外单独执行原有会话/构建 FFI、Git FFI、新增效率功能 FFI 共3项全部通过。新增实际 FFI 用可丢弃 Flutter 工程验证多配置与 Unicode 字段跨设置更新保留、带百分号与 emoji 的源码坐标、编辑器参数字面量传递、真实 Flutter 测试失败和仅重跑该失败名称，不启动个人编辑器。最后紧凑选择器对齐调整后36项选择器/Git/效率功能定向测试再次通过。完整 flutter analyze 无问题，24个修改的 Dart 源码/测试文件格式及 git diff --check 通过。

Rust 最终全套96项、严格 all-targets Clippy 与格式检查通过。新增覆盖旧设置兼容、原子保存保留字段、原始草稿/容量校验、相同开关值不丢待重载变更、显式 capability=false、去抖/禁用/停止释放、源码普通百分号与 UTF-16 列、机器事件关联/失败码/精确正则/取消/退出迟到注册及 Windows 直接 dart.exe 执行测试命令。并行检查曾暴露编辑器测试把观察窗口当作解释器已运行的时序假设；已改为就绪文件和有界轮询，最终96项全量通过。代码交叉审查还修复配置晚恢复丢元信息、保存期间新草稿中止既有启动、终态漏尾日志及带空格源码路径等问题。

真实自动热重载使用本轮创建、带所有权标记的 macOS Flutter 3.38.3 / Dart 3.10.1 样例，命令为 sdk_smoke 的 --auto-reload 模式，设置路径为此次专用临时文件。通过正式核心/DAP 启动，修改 Dart 后实际 reassemble 输出新标记，仅发生一次自动热重载；关闭开关后再修改不触发，随后手动热重载、热重启与停止均通过。关闭测试拥有的会话和 daemon，未操作用户业务工程。该可复现模式及安全前提已写入 development.md。

另7项临时实际控件预览测试通过，检查浅深色1400px/560px配置和编辑器设置，以及560px测试面板、340px日志/网络共11张截图；窄窗口项目名完整可读，操作、配置与筛选控件无布局溢出。截图使用样例和测试字体，少量汉字回退缺字不作为正式宿主字体验收；临时测试已删除，图片保留在临时目录。Windows/Linux 本轮未实机运行，测试面板目前支持宿主单元/Widget测试，不包含设备集成测试调度、覆盖率或测试名称静态解析。README、usage、compatibility-baseline、implementation-scope及需求文档同步本轮实现与边界。

本次 macOS Release 构建成功：`build/macos/Build/Products/Release/Flutter Dev.app`（62.5MB），包含六项增强及最终窄窗布局。已核验主程序和 Rust 核心 framework 打入包中；未重启用户正在运行的旧实例，未将样例验收等同于用户业务工程回归。

## 自动热重载系统监听与漏触发修复

2026年10月15日至16日。Rust 按 canonical 项目路径共享 `notify` 系统目录监听，正常每8秒进行有界轮询校验，监听或扫描故障按2秒退避并恢复；事件通过原子标记合并，600ms防抖，创建、删除、重命名、原子替换及目录重建均参与检查。首次及原生保存批次校验内容摘要，轮询复用未变元数据的摘要，原生事件与轮询共用基线去重。会话独立消费变更版本，忙锁不消费，请求中新增版本在完成后补执行，编译失败仅消费此次尝试，不无限重试。

依赖范围依据最近祖先 package_config、lock 来源、pubspec/overrides 及 workspace 解析，覆盖目录外、传递及覆盖的本地依赖 lib，排除 hosted/Git 缓存和 SDK。配置损坏或曾有配置暂时缺失时保留旧根，扫描失败不清基线。新依赖仍需用户执行 pub get；不自动热重启或编译原生代码。读取、目录数、深度和文件数维持明确上限，详细限制见 usage.md。未修改公开 Rust API，未手写桥接生成结果。

新增9项自动热重载回归和2项 Session 回归，覆盖原生变化4秒内响应、连续变化合并、8秒周期去重、可控屏蔽事件后轮询恢复、注入监听失败后保留基线、共享监控及最后订阅释放、本地依赖图、配置损坏/缺失、编译失败与禁用/停止、忙锁保留及请求中再保存补执行。最终完整 Rust 103项通过，默认并发11.69秒、受控4线程17.07秒；严格 all-targets Clippy、Rust格式及 git diff --check 通过。首次全量与其他构建并行时，原有两项 DevTools 测试在 starts.jsonl 的3秒启动观察窗口超时；未改这些测试或生产逻辑，独立7项及后续两轮完整回归均通过。

默认工具执行沙箱静默屏蔽 macOS FSEvents：原生专项的4秒上限会失败，而较长等待可能仅由8秒轮询通过。故原生专项及最终真实样例在允许宿主文件事件的执行环境运行；额外可控事件屏蔽用例验证轮询兜底。不能把沙箱内延迟触发等同于原生监听通过，正式应用的 Release entitlements 未启用 App Sandbox。

最终真实验收使用本轮创建且应用及外部依赖均有所有权标记的可丢弃 macOS 样例，专用设置位于临时目录；SDK Flutter 3.38.3 / Dart 3.10.1。运行 sdk_smoke 的 `--auto-reload-dependencies`：应用保存至实际 reassemble 输出1.0139秒，目录外 path 包保存0.8105秒，均满足6秒上限；再等待10秒，自动重载总数严格为两次。关闭开关后两处保存均不自动触发，手动重载实际读到两处最新标记，热重启、停止收敛 Ended 和 shutdown_core 均成功，临时样例残留进程为0。复现约定与命令已写入 development.md；未操作用户业务工程或个人应用设置。

Flutter analyze 无问题，完整 Flutter 测试183项通过、5项条件跳过；另重建动态库并使用隔离设置执行实际 FFI 会话回归1项通过。本次无界面改动，未重新执行截图验收；Windows/Linux 的系统监听未实机验证。

最终 `flutter build macos --release` 成功，产物 `build/macos/Build/Products/Release/Flutter Dev.app`（65.4MB）。主程序包含 arm64/x86_64，Rust核心 framework 已打入应用，`codesign --verify --deep --strict` 通过。未替换或重启用户正在运行的旧应用，打包及样例验证不代表用户业务工程已回归。

## 构建目标版本展示

2026年10月16日。构建配置、任务列表和详情新增只读 `version+build_number` 展示，例如 `1.2.3+45`。Rust 从目标项目 `pubspec.yaml` 读取版本并应用当前参数中的 `--build-name` / `--build-number` 覆盖，支持等号和独立参数值、重复参数，以及独立 `--` 分隔；其他带值参数的内容不会被误作版本选项。无效或缺失的 pubspec 版本显示未配置，缺少的版本字段不臆造平台默认值。界面提供刷新和失败重试，参数变化200ms防抖并隔离迟到结果；不修改项目文件或注入版本参数。

新增 `BuildVersion` 与 `read_build_version` API，官方重新生成双端桥接；`BuildSnapshot.version` 固定记录创建任务时的配置版本，列表和详情复用快照，不受后续 pubspec / 参数修改影响。读取失败仅提示并记录日志，不新增构建拦截；旧快照没有版本时显示“未读取”。文件读取保持1 MiB上限，Rust 继续负责构建和配置读取，Flutter 只保存预览及展示投影。

本次 Flutter analyze 无问题，构建相关27项定向测试通过；全套193项通过、3项条件跳过（两项设计预览、需要真实SDK的生产力集成样例）。全套运行已加载此次构建的原生库，专用临时设置文件隔离个人设置；实际 FFI 验证 pubspec 读取、两种参数覆盖、任务开始后修改 pubspec 仍保留快照版本，以及预览读取新版本。界面覆盖参数无效、读失败重试、手动刷新、预设切换、焦点保留、迟到结果、销毁时取消读取、历史任务及浅深色窄窗口。

Rust 格式和严格 all-targets Clippy 通过，13项构建专项测试通过（其中5项新增版本解析及快照用例）。首次沙箱全套108项中105项通过，3项原生文件监听 / 自动热重载测试因未收到事件而超时；正常权限下重跑9项自动热重载与1项会话专项全部通过，包括这3项失败。该行为与既有沙箱静默屏蔽 FSEvents 的已知限制一致，本轮未修改监听实现。Dart 格式与 git diff --check 通过。

本轮未执行用户业务工程打包、修改业务项目版本或重新验收 Windows / Linux；工作区既有未提交改动保留。

本次 macOS Release 构建成功：`build/macos/Build/Products/Release/Flutter Dev.app`（65.6MB），包含版本预览与新任务版本快照。未重启用户正在运行的旧应用，需重启新构建后加载。

## 同设备 iOS 多项目日志隔离

2026年10月20日。真实双项目复现确认两个问题：Flutter SDK 按可执行文件名 `Runner` 读取设备日志，不同应用的输出会进入同一通道；VM Service 地址也从这个共享日志源发现，两个独立 bundle 的会话实际曾连接到相同 VM URI。仅在工作台按 sessionId 分页或换成 VM 输出订阅不足以修复错误的调试连接。

修复对所选 SDK 明确识别的 iOS Debug / Profile launch（含 noDebug）分配独立 VM 服务端口，设备/宿主端口一致，并显式分离 DDS 端口，使模拟器和设备发现时按端口过滤。端口在本工具活动会话间不复用，终态释放逻辑预约，不占着监听 socket 阻止模拟器绑定。已有端口参数统一校验；设备发现错误让会话明确失败，保留 Preparing、SDK 回退信息及终态事件，不静默退回混合日志通道。

Rust 按当前会话 URI 订阅 VM Stdout / Stderr，支持 DDS 在订阅确认前发送的启动历史、跨事件 UTF-8、多行、独立换行及64 KiB长行分段；消息上限1 MiB，保留核心原有日志容量和分页。共享设备 stdout / console 及无前缀续行不入库；DAP 进度事件展示启动状态，工具 stderr 和编译诊断保留。同 URI 热重启复用连接，URI 变化和停止会取消旧连接；日志连接失败或断开明确 warning，不自动重放历史。附加、Release 和非 iOS 路径维持原实现，未把它们声明为已修复。

真实验收使用 Flutter 3.38.3 / Dart 3.10.1、已启动的 iPhone 17 Pro / iOS 26.0 模拟器，以及本轮创建的两个不同 bundle ID、均带所有权标记的可丢弃项目。最终样例两会话的 VM URI 端口分别61450和61473，进程分别85202和85220；各自收到普通 print、多行 print 续行、stderr.writeln 和 debugPrint，未出现另一项目 marker。初次启动及分别热重启后各忽略首批积压日志，再持续检查新输出10秒，三阶段全部通过；热重启改变对应 isolate 且保持 VM 归属。样例使用临时设置，退出时清理其拥有的会话与 daemon，未操作用户业务工程或个人设置。复现命令与样例约定见 development.md 的 `session_logs_smoke`。

最终 Rust 全套125项串行测试通过，严格 all-targets Clippy、格式和 `git diff --check` 通过。Flutter analyze 无问题，日志面板与工作台28项定向测试通过，包含同代次会话切换、旧分页迟到、深浅色和窄窗口。重新构建原生动态库并以专用临时设置执行实际 FFI 会话回归，1项通过，涵盖 SDK 回退 warning 与终态事件。没有修改 Flutter 布局或公开桥接 API，不重新生成桥接、不重复截图验收。真实 SDK 编译失败、iOS 实体设备、Profile / noDebug 目标、附加 / Release 隔离及 Windows / Linux 宿主尚未实机验收。最终测试的两个样例进程均已停止，专用样例应用已从模拟器卸载。

本次 `flutter build macos --release` 成功，产物 `build/macos/Build/Products/Release/Flutter Dev.app`（66.6MB）。未自动替换或重启用户正在运行的实例，需要退出旧工作台后启动新构建，并重新启动项目会话加载隔离逻辑。

## Windows 安装包流水线

2026年10月21日。新增 Windows x64 专用 Actions 工作流，以当前源码构建 release，由 cargokit 同时编译和打包 Rust 核心。PowerShell 脚本暂存完整发布目录并附带 Visual C++ x64 CRT，Inno Setup 生成当前用户安装器，另提供便携 ZIP 和 SHA256 文件；产物保存30天。流水线使用临时设置文件，检查静默安装、已安装 Rust DLL 的真实 Git FFI 调用、应用启动10秒及卸载。进程存活检查不代表全部界面和 SDK 功能已验证。

本机为 macOS，Flutter analyze、两个工作流的 actionlint 和 git diff --check 通过。首次远端执行发现 job env 不支持 runner.temp 上下文，已改用工作区 build 内隔离设置路径，并同步修正原有 desktop 工作流。干净 checkout 的应用分析还扫入 cargokit 的独立 Dart 工具，因其依赖尚未解析产生133项问题；根分析配置现排除随项目交付的 cargokit 目录，不修改工具源码，仍检查应用、自有插件与测试。

修正后的 [Windows 运行](https://github.com/pillarxie/flutter_dev/actions/runs/39567042776) 已通过静态分析、Release 编译、安装器/便携 ZIP 生成和静默安装；安装后的真实 FFI 检查发现 Git 不接受 Rust canonicalize 返回的 Windows verbatim 路径。现在仅对 Git 命令参数转换盘符/UNC 前缀，保留文件访问和 API 返回的 canonical 路径；FFI 测试按目录身份比较，避免两种合法路径表示的字符串差异。

三平台 baseline 还发现 Windows SDK 的 workspaceFolder 展开产生 verbatim 混合分隔符路径，现仅在 Windows 统一分隔符；新增 Unicode 真实目录解析测试。Workspace 两项测试的 Unix 绝对路径样例改用临时目录，不改生产校验合同。本机 Git 11项、SDK 9项、Workspace 5项定向测试通过，Cargo 格式与严格 lib/tests Clippy 通过。Windows 修复后的完整结果以随后远端运行记录为准，暂不记为已通过。未执行 Windows 人工交互、业务工程回归或安装器代码签名。

[a28507f 对应安装包运行](https://github.com/pillarxie/flutter_dev/actions/runs/39568377256) 已通过 Release、安装器生成、静默安装、安装后 Git FFI、应用存活10秒及卸载，产物已上传。对应完整 Windows baseline 的76项 Rust 测试通过，但全套 Flutter FFI 仍发现 cmd.exe 无法执行 canonical verbatim Flutter 批处理路径，影响 SDK 探测。随后仅在批处理调用处转换程序/当前目录/独立路径参数，复用 Git 路径转换；普通 exe、shell 字符拦截与 Job 所有权保持原状。测试 fixture 改用 `%~1` 识别已加引号参数，SDK 路径按目录身份比较。本机 Process 11项及 Git 11项测试、all-targets Clippy、格式检查通过；新增两个 Windows 条件测试等待远端执行。安装验证现同时执行完整核心 FFI 与 Git FFI，使用实际安装后的 DLL。

最终安装包源码为 `66185753b079f642ae35051e5234c00886e7d396`，打包分支为 `codex/windows-package-20261021`。[Windows package #6](https://github.com/pillarxie/flutter_dev/actions/runs/39569902511) 全部通过：Windows Release、安装器与便携 ZIP、静默安装、安装后真实核心 FFI 与 Git FFI（2项通过）、进程存活10秒、卸载和产物上传。Artifacts 的 [FlutterDev-windows-x64-6](https://github.com/pillarxie/flutter_dev/actions/runs/39569902511/artifacts/12332032313) 保存至2026年11月20日。

已下载产物至本机忽略目录 `build/windows/downloads/`，核对 GitHub 外层 ZIP 摘要、内部 SHA256SUMS，以及便携版 EXE、Rust/Flutter DLL、Visual C++ CRT 均为 x64 PE，Flutter data/assets 完整。安装器 `FlutterDev-0.1.0+1-windows-x64-setup.exe` 为12,669,057字节，SHA256 `373da832b937eee61c87526ebfdec66ddd2af29617c31debf6859a1cad9798e8`；便携 ZIP 为15,232,122字节，SHA256 `2080ec79181dcda2552009a5d4b1fb44795c863848276f22fa363c81d0bfcc62`。

同源码的 [Desktop baseline](https://github.com/pillarxie/flutter_dev/actions/runs/39569902626) 中，Windows 的 Rust 78项、Flutter 192项通过/4项条件跳过，格式、严格 all-targets Clippy、分析和 Release 全部通过；新增真实 canonical 批处理与 shell 字符拒绝用例、实际 SDK/Git FFI 均通过。Linux 的 Rust 126项、Flutter 193项通过/3项条件跳过及 Release 全部通过。macOS 首次因未改动的 auto_reload 时序测试失败，已仅重跑该 job 一次，撰写时尚未完成，不将整套三平台 CI 记为通过。

Windows 构建有第三方 WebView2 C4458 编译警告，Actions 有 Node 弃用提示，均未阻止成功产物。安装器未签名；未进行 Windows 人工界面/WebView2 交互、网络共享目录或用户业务工程真实 SDK 调试验收。源码快照通过临时 Git 索引提交，当前本地主分支及原有暂存区保持不变，构建产物不入库。

## Windows 首窗、后台进程及用户目录修复

2026年10月22日。版本更新为 `0.1.1+2`。Flutter 首个加载帧提交后才初始化原生核心，失败可重试，卸载后的迟到结果被忽略。Rust 的受控后台进程增加 `CREATE_NO_WINDOW`，保留创建挂起、Job 分配后恢复及独立编辑器路径；新增真实 exe、cmd/bat 后代的控制台 API 检查及进程树隔离测试。存活 SDK daemon 的设备/模拟器请求复用已有探测结果，并发首次请求合并创建，死 daemon 重探测；其他 SDK 的慢探测不阻塞存活 daemon 查询。添加项目后的排队 Git 刷新复用已在进行的请求。

Windows WebView2 显式使用 `%LOCALAPPDATA%\flutter_dev\WebView2`，不在安装目录创建缓存；创建迟到及离页均释放环境，兼容锁定插件0.6.0的 dispose channel 问题。安装器继续使用 `PrivilegesRequired=lowest` 与当前用户默认目录。旧安装器与主程序的实际 manifest 均为 `asInvoker`；用户报告的交互 UAC 原因尚未复现，不能把静默安装或 manifest 检查等同于已定位该弹窗原因。

本机 Rust Process 11项及 Device 5项通过，严格 all-targets Clippy、格式与 `git diff --check` 通过。Flutter 定向32项及完整 Dart analyze 通过。本机 Flutter 已为3.47.7，辅助测试中排除了4项原有 Git 菜单布局用例，它们触发该版本新增的 ListTile 断言；正式构建/回归使用固定 Flutter3.38.3，不改锁文件或升级项目依赖。新增 Flutter/测试 API 另对照官方3.38.3源码核实兼容。

新增 `verify-windows-startup.ps1` 与 `verify-windows-install.ps1`，分别验证完全脱离控制台的父进程下的真实首窗/终端观察，以及临时标准用户令牌下不传 `/DIR` 的默认安装、目录写入、10秒存活和同用户卸载。前者使用 Job 与启动 gate 限制进程所有权；后者最终采用交互桌面中的显式 profile 加载/卸载与 Credential 普通用户进程，禁止 Session0 和管理员令牌代测。两种验证均输出 JSON，流水线只在验证成功后上传包；同运行源码缓存只复用安装包字节，每次仍重新验证。

首轮新增 Windows 探针把 `GetConsoleProcessList=0` 当作无窗口的必要条件，导致2项测试失败。Windows Server2025 独立真实 exe 及 cmd/bat 后代证据显示，`GetConsoleWindow=0`、`IsWindowVisible=false` 时内部计数仍分别为1和2；现保留无窗口句柄/不可见断言，将进程计数仅作诊断，不改生产启动方案，也不放宽进程树所有权验证。

源码 `7ac9a2bda9a8fcefa604f58c610536077393b6e8` 的 [Desktop baseline #10](https://github.com/pillarxie/flutter_dev/actions/runs/39744690108) 中，Windows 的 Rust84项、Flutter206项通过/4项跳过，格式、严格 all-targets Clippy、分析和 Release 全部通过。Linux 的 Rust129项、Flutter207项通过/3项跳过及 Release 全部通过。macOS 首轮及单独重跑一次仍在未修改的 `auto_reload/tests.rs:247` 失败（129通过、1失败），后续 Flutter 检查跳过；不能将整套三平台 CI 记为通过。

同源码 [Windows package #8](https://github.com/pillarxie/flutter_dev/actions/runs/39744690088) 已完成 Release、安装器和便携 ZIP，安装后真实核心/Git FFI通过。在 Windows2022 的 Session2 中首窗1296ms，20秒终端观察为0，应用正常关闭。新临时普通用户的管理员组成员关系、管理员角色及令牌提升均为false，默认安装、安装/设置目录写入、应用存活10秒和同用户卸载全部通过，任务自然退出0；但控制器最终删除临时 profile 因系统仍持有文件失败，因此该运行整体失败、未上传安装包，仅上传诊断。后续正在修复验证器 profile 生命周期，不能将本次记录记为最终交付成功。

Windows Server2025 的旧包验证同样通过普通用户产品检查，但三次计划任务路径的测试留下的临时 profile 仍被系统持有；第三次已显式释放控制器的 profile 引用，系统仍有额外引用，故停止此路径。对应账号、任务、进程、临时登录权限及 staging 已清理，未强制重启或停止系统服务。精确 SID/目录、只读事件及后续受保护清理脚本位于本机忽略目录 `build/windows/server-standard-user-validation/`。旧包窗口与探针证据仅验证验证器和平台行为，不代表新版缺陷已复现或所有功能已回归。Windows10/11 个人业务工程和 WebView2 人工交互未验收。
