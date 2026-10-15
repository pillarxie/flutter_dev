# Flutter Dev 设计图

生成方式：内置 imagegen。设计图用于 Flutter 控件实现的布局参考。

## 浅色最终提示词

Create a high-fidelity desktop application UI design mockup for 'Flutter Dev', a macOS Flutter development workbench. One single straight-on screenshot, 1440x960 canvas, LIGHT theme. Modern minimalist restrained Apple design language, precise typography, generous but practical spacing, monochrome white and pale gray surfaces, hairline separators, subtle rounded corners, Apple blue as the ONLY accent. No perspective, no decorative illustrations, no gradients, no fake analytics. The app has two columns: 248px left sidebar with small Flutter Dev brand, a top '新增项目' button, project list with expandable nested historical sessions and a small play icon on each project row. Two example projects 'Clerk Platform' and 'Flutter Demo'; active nested session 'iPhone 17 Pro · Debug' with small running indicator. Bottom sidebar '应用设置' and a compact sun/moon appearance control. Main right content: top header title 'Clerk Platform', subtitle 'iPhone 17 Pro · Debug', right aligned compact icon controls pause, hot restart, hot reload, stop, blue subtle accent on appropriate actions. Below compact tabs '日志' selected, '调试器', 'DevTools', '测试'. Main area is a beautiful sparse developer console, monospaced typography, small muted timestamp/category column, a few lines 'Launching lib/main.dart on iPhone 17 Pro in debug mode...', 'Flutter SDK 3.38.3', 'Connected to the VM Service', 'Application running'. Toolbar has search field and copy/refresh icons. Footer subtle status '运行中' and '4 条日志'. Chinese UI labels must be crisp and legible. Native Apple desktop feel, understated premium craftsmanship. Render the application content only, no OS menu bar, no fake titlebar traffic lights.

## 深色最终提示词

Use case: ui-mockup. Asset type: high fidelity macOS developer desktop app screenshot, 1440x960. Create the DARK theme counterpart of Flutter Dev with precise restrained Apple styling. Charcoal #1c1c1e main canvas, slightly lighter neutral sidebar #242426, thin separators #353537, warm white text and muted gray secondary text, Apple blue #0a84ff the only accent. No gradients, no illustrations, no glossy glass. Two columns, sidebar 248px with small Flutter Dev brand, blue '新增项目' button, section '项目', project 'Clerk Platform' expanded with nested historical sessions 'iPhone 17 Pro · Debug' selected and 'iPhone 16 · Debug' dimmed, second 'Flutter Demo' project. Trailing play icons on project rows. Bottom '应用设置' and compact segmented sun/moon toggle with moon selected. Right header title 'Clerk Platform', subtitle 'iPhone 17 Pro · Debug', top right compact rounded controls '暂停', '热重启', '热重载', '停止'. Tabs '日志' selected blue underline, '调试器', 'DevTools', '测试'. Hairline divider and search toolbar '搜索日志内容…' with copy and refresh buttons. Console sparse monospaced lines with muted category column: 'Launching lib/main.dart on iPhone 17 Pro in debug mode...', 'Flutter SDK 3.38.3', 'Connected to the VM Service', 'Application running'. Large uncluttered empty console space. Bottom status bar '运行中' blue dot and right '4 条日志'. Chinese UI labels crisp. Premium practical desktop proportions, content only, no menu bar or fake traffic lights.

## 文件

- `workbench-light.png`：浅色 imagegen 设计图。
- `workbench-dark.png`：深色 imagegen 设计图。
- `implemented-session-light.png` / `implemented-session-dark.png`：实际 Flutter 会话页渲染。
- `implemented-settings-light.png` / `implemented-settings-dark.png`：实际 Flutter 设置页渲染。

实际界面保留真实数据与现有能力：日志只显示核心返回的分类和文本，会话状态可见，SDK 信息显示实际解析值。

## 构建、设置与应用图标（2026-10-14）

生成方式：内置 imagegen；以下为最终提示词。页面设计图作为 Flutter 控件参考，交互沿用现有能力。图中的示意路径不写入真实设置，构建目录仅控制成功后打开的位置，自动打开产物目录并非可切换设置。

### build

```text
Use case: ui-mockup
Asset type: Flutter Dev desktop build dialog design reference.
Primary request: high-fidelity straight-on UI screenshot of a modern restrained Apple-style build configuration dialog, light theme, practical layout easily implemented in Flutter. Single 900x900-ish canvas, content only. Pale neutral background, white grouped cards, hairline gray borders, 12px corners, black typography, muted secondary labels, Apple blue only accent. Header small blue package outline icon in soft blue rounded tile, title '构建应用', subtitle 'Clerk Platform · 配置并生成发布产物', close icon. Below two compact grouped cards. First section '构建配置': top row preset dropdown 'Android Release' with small add and save preset controls; below two columns '预设名称' text field and '构建平台 / 产物类型' dropdown 'Android APK (apk)'; below full width '构建参数（JSON 数组）' multiline monospaced field '["--release"]'; below '产物目录（可选）' field with muted explanation. Second smaller section '命令预览' with caption 'Flutter SDK · 自动选择' and monospaced 'flutter build apk --release'. Below compact '构建输出' section with gray waiting status pill '等待构建', a quiet empty terminal '构建开始后，日志将显示在这里'. Fixed footer hairline divider, muted note '构建成功后自动打开产物目录', right aligned secondary '关闭' and blue '开始构建'. Generous but efficient spacing, no decorative hero, no gradients, no charts, no device mockup, no extra functionality. Chinese text crisp.
```

### settings

```text
Use case: ui-mockup
Asset type: Flutter Dev application settings page design reference.
Primary request: a single high-fidelity straight-on native desktop application screenshot, modern minimalist restrained Apple style, LIGHT theme. White main canvas with soft neutral gray grouped panels, hairline borders, rounded corners 12px, black type, muted gray text, Apple blue only accent. Practical compact typography, no decorative hero or gradients. Canvas wide 1200x850 proportions. Left sidebar 220px pale gray with small abstract blue app mark and 'Flutter Dev', '新增项目' button, project 'Clerk Platform', bottom selected '应用设置'. Right workspace top native-like content header title '应用设置', subtitle '个性化工作台与开发环境'. Below centered readable column max width 760 with generous 32px margins. Section label '外观' with small sun icon, supporting subtitle '选择适合你的工作方式'. White grouped card contains two side by side selectable theme preview tiles '浅色' and '深色': miniature schematic sidebar and main panel, light tile selected with fine blue outline and small checkmark. Realistic UI previews built of simple shapes, no drawings. Below section 'Flutter SDK' with small code icon, caption '设置全局默认开发环境'. White grouped card title '全局默认 SDK', short muted note '项目独立配置优先，未配置时使用全局默认 SDK。'; label 'SDK 路径', horizontal path field '/Users/developer/flutter' with compact folder browse button; help '选择包含 bin/flutter 的 SDK 根目录'; next row secondary clear '清除默认 SDK' and right blue '验证并保存'. Hairline divider then saved status small checkmark blue and '当前已保存的默认 SDK' with monospaced path. Below panel quiet information row '修改将在下一次检查或启动时生效，已运行会话不受影响。' Bottom small muted 'Flutter Dev' app signature. Crisp Chinese text, practical layout, no invented toggles, no extra features, no menu bar or traffic lights.
```

### icon

```text
Use case: logo-brand
Asset type: production macOS/Windows/Linux desktop application icon for Flutter Dev, a Flutter build and debug workbench.
Primary request: design one distinctive premium native desktop app icon, restrained modern Apple aesthetic. A single centered rounded-square icon tile occupying 86 percent of square canvas, fully transparent outside the tile. Soft off-white porcelain rounded square with extremely subtle tactile edge and restrained soft shadow. Inside, a bold simple geometric mark combining a forward play triangle and two folded angular developer-code brackets, suggestive of running and building code. Electric Apple blue and deeper cobalt facets, clean crisp silhouette, only 2-3 large geometric planes, high legibility at 16px. Original abstract mark, do not reproduce Flutter or Apple logos. Calm precise balanced proportions, generous inner padding, flat nearly vector geometry with only subtle dimensional depth. No text, letters, wordmark, border frame, extra small details, mockup scene, surrounding objects, or watermark. Square icon on genuinely transparent background.
```


资源：`build-light-imagegen-v1.png`、`settings-light-imagegen-v1.png`；图标源文件 `../../assets/branding/app-icon-source.png`，导出脚本 `../../scripts/generate_app_icons.py`。浅色设计布局同步应用到深色主题；实现预览使用测试数据，不代表实际构建结果。

实际控件预览：`build-light-implemented-v1.png`、`build-dark-implemented-v1.png`、`settings-light-implemented-v1.png`、`settings-dark-implemented-v1.png`。最小窗口预览为 `build-*-narrow-v1.png` 和 `settings-*-narrow-v1.png`（560×500）；中间内容可滚动，构建底部操作固定。执行 `flutter test test/design_preview_test.dart --dart-define=DESIGN_PREVIEW=true` 可在 macOS 使用本机字体与测试数据重新导出；普通测试默认跳过此预览入口。设计稿中的命令复制入口未作为功能新增。


## 项目配置页第二次布局调整

沿用上面的设计语言，根据用户布局要求直接调整 Flutter 控件。新预览为 `configuration-light-v2.png`、`configuration-dark-v2.png`；高级区展开效果为 `configuration-advanced-light-v2.png`、`configuration-advanced-dark-v2.png`，窄窗效果为 `configuration-narrow-light-v2.png`、`configuration-advanced-narrow-dark-v2.png`。这些文件是实际控件渲染，使用测试项目与设备数据。

## 下拉菜单优化

沿用既有设计语言，使用 Flutter MenuAnchor 还原紧凑圆角浮层、设备图标、选中勾选和模式说明。设备、模式、平台、模拟器和窄窗预览为 `select-*-v3.png`，均是实际控件渲染，使用测试数据和系统字体；预览启用与实际应用一致的柔和阴影。
