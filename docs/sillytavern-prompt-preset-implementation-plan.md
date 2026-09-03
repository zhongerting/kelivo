# Kelivo SillyTavern 提示词预设实施计划

## 1. 目标

在 Kelivo 中增加独立的“提示词预设”功能，使用户可以从 SillyTavern
预设 JSON 导入提示词条目，并在不同助手上选择使用一个预设。

本功能只复用预设中影响模型生成的提示词数据，不复刻 SillyTavern 的
正则、脚本、采样参数或插件运行环境。最终交付物必须包含可在 Android
真机安装的 Release APK。

## 2. 已确认的产品决策

1. 每个助手最多选择一个提示词预设，也可以选择“不使用预设”。
2. 一个预设可以包含多个提示词条目，条目可以分别启用或关闭。
3. 保留 SillyTavern 条目的 `system`、`user`、`assistant` 角色。
4. 保留 `prompt_order` 定义的原始顺序。
5. 使用 `chatHistory` marker 区分位于聊天记录之前和之后的提示词。
6. 不在聊天主界面增加快捷入口。
7. 在设置页增加预设库入口；在助手编辑页选择该助手使用的预设。
8. 新导入的预设默认不绑定任何助手，避免导入后改变现有对话行为。

## 3. 明确不做的内容

以下数据不得导入、持久化为可执行内容或在运行时执行：

- `extensions.regex_scripts` 和 `extensions.SPreset.RegexBinding`
- `extensions.tavern_helper.scripts`、HTML、JavaScript 和 iframe
- `SPresetSettings`、`regexes-bindings` 等插件配置条目
- 温度、Top P、Token 上限、推理强度、联网搜索等模型参数
- SillyTavern 的输出后处理、摘要裁剪、思考折叠和行动选项按钮
- 任意形式的 `eval`、动态函数调用或从 JSON 加载可执行代码

因此，如果提示词要求模型输出 `<思考>`、`<摘要>` 或 `<选项>`，这些标签和
内容会作为普通文本显示，并进入后续聊天历史。这是本阶段的预期行为，不应
通过隐藏标签或执行预设正则来“修复”。

## 4. 建议架构

新增独立 feature：`lib/features/prompt_preset/`。不要把预设伪装成世界书，
也不要把条目直接写入现有指令注入库。可以复用两者的 UI 和 Provider 模式，
但数据、选择状态和上下文来源必须独立。

建议文件：

```text
lib/core/models/prompt_preset.dart
lib/core/providers/prompt_preset_provider.dart
lib/core/services/prompt_preset_store.dart
lib/features/prompt_preset/services/prompt_preset_import_service.dart
lib/features/prompt_preset/services/prompt_preset_macro_service.dart
lib/features/prompt_preset/pages/prompt_preset_page.dart
lib/features/prompt_preset/widgets/...
```

### 4.1 数据模型

`PromptPreset` 建议字段：

```text
id                 Kelivo UUID
name               显示名称，默认取去除扩展名后的文件名
sourceFormat       sillyTavern / kelivo
entries            有序 PromptPresetEntry 列表
```

`PromptPresetEntry` 建议字段：

```text
id                 Kelivo UUID
sourceIdentifier   SillyTavern identifier，仅用于追踪和报告
name               条目名称
content            原始提示词正文
enabled            是否参与下一次生成
role               system / user / assistant
anchor             beforeChatHistory / afterChatHistory
sourceOrder        prompt_order 中的原始序号
```

暂不需要给 `Assistant` 模型增加字段。参照 `WorldBookStore`，在
`PromptPresetStore` 中保存 `assistantId -> presetId` 映射。映射中每个助手
只能有零个或一个 preset ID；删除预设时必须清理所有引用该 ID 的映射。

建议存储键：

```text
prompt_presets_v1
prompt_preset_active_by_assistant_v1
```

不要提供 `__global__` 回退。没有显式选择的助手就不使用预设，防止新助手
意外继承其他助手的预设。

## 5. SillyTavern JSON 导入规则

### 5.1 格式识别

满足以下条件时识别为 SillyTavern 提示词预设：

- 根节点是 JSON object；
- `prompts` 是数组；
- `prompt_order` 至少包含一个具有 `order` 数组的对象。

优先使用 `character_id == 100001` 的 `prompt_order`；没有时使用第一个合法
order。导入器必须是纯解析器，不得执行 JSON 中的任何字符串。

### 5.2 条目选择

以选中的 `prompt_order.order` 为权威顺序，按 `identifier` 关联
`prompts`：

1. `marker == true` 的条目不导入为提示词。
2. `chatHistory` marker 不导入，但其序号是前后位置的分界线。
3. marker 之前的普通条目标记为 `beforeChatHistory`。
4. marker 之后的普通条目标记为 `afterChatHistory`。
5. 没有 `chatHistory` marker 时，普通条目统一使用 `beforeChatHistory`。
6. 正文为空的条目跳过。
7. `SPresetSettings`、`regexes-bindings` 等已知插件配置条目强制跳过。
8. `enabled` 以 `prompt_order.order[].enabled` 为准。
9. 不在 `prompt_order` 中的条目不导入；在报告中计为未排序/未使用条目。
10. 缺失或非法角色回退为 `system`，并产生调整警告。
11. 重复或找不到对应 prompt 的 identifier 跳过并报告。

对于 `injection_position != 0` 的“指定深度注入”条目，本阶段不假装兼容：
条目可以保留到预设中，但默认关闭，并在导入报告中注明“不支持指定深度，
已关闭”。当前“仓鼠之神 V4.8.2”样本的有效条目不依赖该能力。

### 5.3 样本验收基线

使用用户本机文件进行手动验收：

```text
C:\Users\HC Zhao\Downloads\仓鼠之神V4.8.2..json
```

预期结果：

- 根 `prompts`：68 项；
- `prompt_order`：67 项；
- 导入普通提示词：59 项；
- 默认开启：40 项；
- 默认关闭：19 项；
- 跳过 marker：8 项；
- 跳过未进入 order 的 `SPresetSettings`：1 项；
- `extensions` 中全部正则和插件数据被忽略且没有执行。

不要把用户的原始预设提交到 Git。测试仓库应新增一个不含敏感内容的最小
fixture，保留相同字段形状即可。

### 5.4 导入结果

`PromptPresetImportResult` 至少提供：

```text
preset
format
importedEntries
enabledEntries
disabledEntries
skippedMarkers
skippedEntries
unsupportedMacroNames
adjustments / warnings
```

UI 必须展示成功数和警告摘要，不能只显示“导入成功”。解析失败不得保存
半成品预设。

## 6. 安全宏兼容

为了使该样本的提示词组合关系有效，需要实现有限、确定性的 SillyTavern
宏转换。首版支持：

```text
{{user}}                 当前用户昵称
{{char}}                 当前助手名称
{{lastUserMessage}}      本次生成前最近一条真实用户消息
{{setvar::name::value}}  在本次预设渲染中设置临时变量，不输出宏本身
{{getvar::name}}         读取本次渲染中的临时变量
{{trim}}                 删除宏本身，并清理条目边缘空白
{{// comment}}           删除注释，不发送给模型
```

要求：

- 宏名称大小写不敏感。
- 按 `prompt_order` 顺序处理已启用条目；关闭条目中的 `setvar` 不得生效。
- 临时变量只在一次生成构建期间存在，不写入聊天、数据库或全局状态。
- 先解析上下文宏和注释，再安全处理 `setvar/getvar`，不得使用 `eval`。
- 未支持宏保留原文，导入时给出名称列表，禁止静默删除。
- 增加长度和循环防护；即使变量相互引用也不得无限展开。

应优先扩展或复用 `PromptTransformer` 的占位符上下文，但预设宏解析应放在
独立 service 中，避免改变现有助手系统提示词的行为。

## 7. 生成请求中的顺序

新增 `injectPromptPresetPrompts`，只读取当前助手选中的一个预设。

构造规则：

1. 按 `sourceOrder` 取得启用条目。
2. 在同一次顺序遍历中完成宏处理。
3. 保留每个条目的原始 role。
4. `beforeChatHistory` 条目按原顺序放到真实聊天历史之前。
5. `afterChatHistory` 条目按原顺序放到真实聊天历史之后。
6. 可以合并相邻且 role、anchor 相同的条目，但不得跨角色、跨 anchor 或改变
   内容顺序。
7. 给插入消息增加独立 `ContextSource.promptPreset` 日志标记，便于在上下文
   查看器验证。

建议在现有世界书注入和 `applyContextLimit` 完成后插入预设。这样预设中的
user/assistant 文本不会误触发世界书关键词，预设也不会被普通聊天条数限制
裁掉。需要更新相关注释并增加测试，确认附件处理仍只作用于保留的真实消息。

Kelivo 各 API provider 可能会把 system 消息汇总为顶层 system/instructions。
验收标准是进入 provider 前的 Kelivo 规范消息保持角色和顺序；provider 为满足
各模型 API 所做的既有规范化不在本任务中重写。

## 8. UI 设计

### 8.1 设置页

在“世界书”附近增加“提示词预设”导航项，使用 Lucide 图标和 ARB 本地化。
进入后提供：

- 从单个或多个 `.json` 文件导入；
- 预设列表及条目数量；
- 展开/折叠预设；
- 编辑预设名称；
- 删除预设并二次确认；
- 查看、编辑、启用/关闭、排序提示词条目；
- role 和聊天记录前/后位置的只读标识；
- 导入结果和不支持内容警告。

移动端可以使用 `CustomBottomSheet` 或应用现有移动端组件；桌面端不得使用
BottomSheet，应使用 dialog 或独立编辑区域。不要创建卡片嵌套卡片。

### 8.2 助手编辑页

在助手的“提示词”页增加“提示词预设”选择器：

```text
不使用预设
预设 A
预设 B
...
```

选择立即通过 `PromptPresetProvider` 持久化到当前 assistant ID。显示当前预设
的启用条目数，并提供跳转到预设管理页的入口。不得在聊天输入栏或聊天页面
增加新按钮。

## 9. 分阶段实施

### 阶段 0：基线与分支

- 阅读 `AGENTS.md`，确认工作树状态。
- 从当前定制分支创建 `codex/sillytavern-prompt-presets`。
- 运行相关现有测试，记录基线，不覆盖用户改动。

完成标准：分支正确，世界书、指令注入和消息构建测试基线已记录。

### 阶段 1：模型、导入器与宏处理

- 新增预设模型、枚举、JSON 序列化。
- 新增严格的 SillyTavern 导入服务和结果报告。
- 新增有限宏处理器。
- 添加脱敏 fixture 和单元测试。

完成标准：样本结构能得到 59/40/19/8/1 的预期统计；扩展脚本未进入模型。

### 阶段 2：存储、Provider 与备份

- 新增 JSON store 和 Provider。
- 实现每助手零或一个预设的选择。
- 删除预设时清理所有助手映射。
- 注册顶层 Provider。
- 将新键加入备份验证/恢复范围，并测试持久化和恢复。

完成标准：重启后预设、条目状态和助手选择保持一致；不同助手互不串用。

### 阶段 3：设置和助手 UI

- 增加中英文 ARB 文案并运行 `flutter gen-l10n`。
- 增加设置页入口和预设管理页。
- 在助手提示词页增加单选预设选择器。
- 覆盖移动端和桌面端布局、空状态、错误状态和无障碍标签。

完成标准：无需进入聊天主界面即可完成导入、逐项开关和助手绑定。

### 阶段 4：生成管线

- 实现 `injectPromptPresetPrompts`。
- 保留角色、原始顺序和 chatHistory 前后 anchor。
- 接入宏上下文和 Context Logger。
- 确认没有选中预设时请求与修改前字节级等价或结构等价。

完成标准：上下文日志能准确显示启用条目的最终 role、顺序和展开后的正文。

### 阶段 5：回归、真机验证和 APK

- 格式化并运行严格分析、聚焦测试和完整测试。
- 在模拟器或已连接设备导入用户样本并核对统计。
- 分别用两个助手验证单预设约束和状态隔离。
- 关闭/开启“行动选项”等条目，检查下一次实际请求上下文变化。
- 构建并安装 Release APK，验证启动、键盘响应、导入和发送。

完成标准：Release APK 可安装使用，无新增 analyzer 问题和测试回归。

## 10. 必须覆盖的测试

至少增加以下测试：

- 原生最小预设 JSON 导入成功；
- 样本形状的 prompts/prompt_order 映射和统计；
- marker、插件配置、空内容、缺失 identifier、重复 identifier 的处理；
- prompt_order 的 enabled 优先于 prompts.enabled；
- role 和 chatHistory 前后 anchor 保留；
- 不读取、不执行、不保存 extensions 中脚本；
- 支持宏逐项展开、变量顺序、关闭条目不产生变量；
- 未支持宏保留并报告；
- Provider 每助手只能保存一个预设；
- 删除预设清理助手引用；
- 预设与选择状态经过备份恢复；
- 生成请求中的 before/history/after 顺序；
- system/user/assistant 角色保持；
- 未选择预设时不改变请求；
- UI 导入报告、条目开关、助手选择和“不使用预设”。

## 11. 验证命令

按仓库要求执行：

```powershell
dart format lib test
flutter gen-l10n
dart analyze --fatal-infos lib test
flutter test
```

先运行新增的聚焦测试，再运行完整测试。若完整测试命中 `AGENTS.md` 已记录的
Windows 路径分隔符等历史失败，必须逐项区分既有失败和新增失败，不能笼统写
“测试通过”。

## 12. Android Release 交付

Release 构建必须遵守仓库 `AGENTS.md`：

- 不交付 Debug APK，避免 Android 输入法严重卡顿；
- 在 ASCII 路径 `E:\devtools\kelivo-apk-build` 更新或暂存源码；
- 必要时使用 JDK 17：
  `E:\devtools\temurin-17\jdk-17.0.20.1+1`；
- 使用现有忽略的 `android/key.properties` 和个人测试签名，不提交密钥；
- 执行 `flutter build apk --release`；
- 使用 `adb install -r` 做安装和启动冒烟测试（设备可用时）；
- 报告 APK 绝对路径、文件大小和 SHA-256。

不得破坏现有自定义功能：快捷指令注入、快捷回复“发送/追加”、关闭官方更新
提示、SillyTavern 世界书导入、调试版共存和自定义启动图标。

## 13. 最终验收清单

- [ ] 设置页能导入 SillyTavern 预设 JSON。
- [ ] 用户样本导入统计符合 59/40/19/8/1。
- [ ] 预设中没有任何正则或 JavaScript 被执行。
- [ ] 每个助手只能选择零或一个预设。
- [ ] 条目可以独立启用、关闭、编辑和排序。
- [ ] role、原始顺序及 chatHistory 前后位置得到保留。
- [ ] 样本使用的安全宏得到正确展开。
- [ ] 未选择预设时不改变现有消息请求。
- [ ] 中英文 UI、移动端和桌面端均可用。
- [ ] 现有定制功能无回归。
- [ ] Release APK 已安装冒烟测试并提供路径、大小和 SHA-256。
