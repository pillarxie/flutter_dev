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
