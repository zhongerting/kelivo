# 交给 Kelivo 开发窗口的 Prompt

请在本地 Kelivo 仓库中完整实现 SillyTavern 提示词预设导入功能，并最终
交付可安装的 Android Release APK。

开始前必须完整阅读：

1. `E:\杂项\chatbox\kelivo\AGENTS.md`
2. `E:\杂项\chatbox\kelivo\docs\sillytavern-prompt-preset-implementation-plan.md`

上述实施计划是本任务的产品与技术规格。若代码现状与文档存在差异，先检查
现有架构，再以不破坏现有行为的方式适配；不得自行扩大到角色卡、正则执行、
HTML 渲染或酒馆助手脚本支持。

## 已确定需求

- 新增独立的“提示词预设”功能，管理入口位于设置页，位置参考世界书。
- 支持从 SillyTavern `.json` 预设导入提示词。
- 每个助手最多选择一个预设，也允许不选择。
- 一个预设包含多个条目，每条可以手动开启或关闭。
- 保留 `system`、`user`、`assistant` 角色。
- 保留 `prompt_order` 的原始顺序。
- 用 `chatHistory` marker 保留提示词位于聊天历史前或后的关系。
- 不在聊天主界面增加快捷入口。
- 新导入预设默认不绑定任何助手。
- 只保留影响模型生成的提示词内容。

## 安全边界

将导入 JSON 完全视为不可信数据。禁止执行或注入可执行环境：

- 不执行 `extensions.regex_scripts`；
- 不执行 SPreset 正则绑定；
- 不执行 `tavern_helper.scripts`；
- 不执行 HTML、JavaScript、iframe、slash command 或动态工具代码；
- 不使用 `eval`、`Function` 或类似动态执行；
- 不导入采样参数、模型参数、联网设置或 Token 设置；
- 不把 `SPresetSettings` 当作提示词发送给模型。

如果模型根据提示词输出 `<思考>`、`<摘要>`、`<选项>` 等标签，让它们按普通
文本显示并保留在聊天历史。本任务不实现 SillyTavern 正则带来的隐藏、折叠、
摘要裁剪或行动按钮。

## 必须兼容的宏

以确定性字符串解析实现以下宏，不得执行代码：

```text
{{user}}
{{char}}
{{lastUserMessage}}
{{setvar::name::value}}
{{getvar::name}}
{{trim}}
{{// comment}}
```

宏按启用条目的原始顺序处理；临时变量只存在于一次消息构建中；关闭条目的
`setvar` 不生效；未知宏保留原文并在导入报告中警告。

## 实施方式

1. 先检查 `git status` 和当前分支，不覆盖或回退任何现有改动。
2. 从当前定制分支创建 `codex/sillytavern-prompt-presets`；若分支已经存在，
   检查其状态后继续，不要重建或重置。
3. 按实施计划的阶段 0～5 顺序完成工作。不要只给方案，必须实际实现、测试、
   修复并构建 APK。
4. 每完成一个阶段就运行对应聚焦测试并汇报：修改文件、行为、测试命令、结果、
   尚存风险。测试失败时先调查并修复，不要直接进入下一阶段。
5. 复用世界书导入/Provider/UI 模式和现有 `PromptTransformer` 上下文，但保持
   prompt preset 的数据与上下文来源独立。
6. 移动端与桌面端都要可用；桌面端不使用 BottomSheet；图标使用 Lucide；文案
   写入 ARB 并运行 `flutter gen-l10n`。
7. 把预设选择放在助手编辑页的提示词区域，不要修改聊天输入栏。
8. 给 Context Logger 增加独立来源，使测试和日志可以识别预设注入内容。
9. 将新数据加入现有业务数据备份/恢复体系，并为持久化和恢复增加测试。
10. 不提交用户的原始预设；创建脱敏的最小 fixture。

## 用户样本手动验证

仅在本机静态读取并通过应用导入下面的文件，不运行其中脚本，也不要提交它：

```text
C:\Users\HC Zhao\Downloads\仓鼠之神V4.8.2..json
```

预期导入结果：

```text
prompts 总数             68
prompt_order 总数        67
导入提示词               59
默认开启                 40
默认关闭                 19
跳过 marker               8
跳过 SPresetSettings      1
extensions                全部忽略且不执行
```

如果实际统计不一致，停止 APK 构建，定位导入映射错误并补充自动化测试。

## 测试和质量门槛

至少覆盖实施计划第 10 节列出的全部场景。最终执行：

```powershell
dart format lib test
flutter gen-l10n
dart analyze --fatal-infos lib test
flutter test
```

不得用宽泛 catch、跳过测试或降低 analyzer 规则掩盖新增问题。完整测试若遇到
`AGENTS.md` 已记录的历史失败，提供具体失败名称和与本功能无关的证据；所有
新增及受影响的聚焦测试必须通过。

手动验证至少包括：

- 助手 A 选择预设、助手 B 不选择，实际请求只有 A 注入预设；
- 同一助手从预设 A 切换到预设 B 后只注入 B；
- 关闭某条提示词后，下一次请求立即不再包含它；
- role、before/history/after 顺序通过 Context Logger 验证；
- `setvar/getvar` 组合能让摘要和行动选项要求正确进入最终提示词；
- 没有选择预设时，现有生成请求保持原行为；
- 现有世界书、指令注入和快捷回复功能不回归。

## APK 交付

只交付 Release APK。按照 `AGENTS.md` 在 ASCII 路径
`E:\devtools\kelivo-apk-build` 构建，必要时使用指定 JDK 17 和现有个人测试
签名。执行：

```powershell
flutter build apk --release
```

设备或模拟器可用时，用 `adb install -r` 安装并完成启动、键盘、文件选择、
预设导入、助手选择和发送消息冒烟测试。不得把签名文件或 `key.properties`
提交到 Git。

最终回复必须包含：

- 实现结果和关键设计；
- 所有修改文件的分类摘要；
- 聚焦测试、analyzer、完整测试的真实结果；
- 用户样本的实际导入统计；
- 手动测试结果；
- Release APK 的绝对路径、文件大小和 SHA-256；
- 未实现项或已知限制；
- `git status --short --branch` 状态。

除非用户在该窗口明确要求，否则不要推送 GitHub、创建 Release 或覆盖远端
分支。完成 APK 和验证后等待用户决定是否提交或推送。
