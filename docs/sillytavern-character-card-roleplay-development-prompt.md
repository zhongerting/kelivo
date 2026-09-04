# 交给 Kelivo 角色卡开发窗口的 Prompt

请在本地 Kelivo 仓库中完整实现“精简 SillyTavern 角色卡导入、RP 助手和历史
推理上下文过滤”功能，并最终交付可安装的 Android Release APK。

开始前必须完整阅读：

1. `E:\杂项\chatbox\kelivo\AGENTS.md`
2. `E:\杂项\chatbox\kelivo\docs\sillytavern-character-card-roleplay-implementation-plan.md`
3. `E:\杂项\chatbox\kelivo\docs\sillytavern-prompt-preset-implementation-plan.md`

第一份实施计划是本任务的权威规格。旧提示词预设计划中“不实现思考隐藏或
裁剪”的说明是旧阶段边界；本任务已经明确增加 RP 助手的“只过滤未来模型
上下文”能力。不要据此删除、回退或重做已经完成的提示词预设功能。

## 当前状态保护

当前工作树可能包含已经实现并由用户测试完成、但尚未提交的提示词预设改动。
开始时先执行并汇报：

```powershell
git status --short --branch
git diff --stat
git log -3 --oneline
```

不得执行 `git reset --hard`、`git checkout --`、clean、stash pop 或覆盖现有
改动。不要在工作树不干净时擅自切换/重建分支。以当前文件内容为基线继续，
并先运行提示词预设聚焦测试，确认现有功能没有被破坏。

除非用户在该窗口明确要求，否则不要提交、推送 GitHub、创建 Release 或修改
远端分支。

## 已确定需求

- 助手增加 `normal` / `roleplay` 类型；旧助手默认为 normal。
- 从 SillyTavern `.json` V1/V2/V3 或 Character Card `.png` 创建 RP 助手。
- 只导入名称、PNG 头像、人物设定、开场白和内嵌世界书。
- 人物设定由 `description`、`personality`、`scenario` 合并，但与 Kelivo 现有
  `systemPrompt` 分开保存、编辑和注入。
- 开场白对应 `first_mes`，每个新对话只插入一次真实 assistant 消息。
- 角色卡 `character_book` 转换为 Kelivo 世界书并自动绑定该 RP 助手。
- RP 助手可以继续选择已经实现的一个提示词预设。
- RP 助手默认开启“从未来上下文中排除历史推理”。
- 本地数据库、备份和聊天界面完整保留推理，维持 Kelivo 现有显示形式。
- 每一次未来 API 请求都从已完成历史回复中删除推理正文，只发送最终正文。
- 当前正在执行的同一轮工具调用必须保留提供商续接所需数据。
- 不在聊天主界面增加快捷入口。

## 严格安全边界

角色卡文件和其中全部字符串都是不可信输入。禁止执行、导入为启用规则或发送
到动态运行环境：

- `extensions.regex_scripts`；
- JavaScript、HTML、iframe、slash command；
- Tavern Helper、JS-Slash-Runner 或其他插件配置；
- `eval`、`Function`、动态 Dart/JS 调用；
- `system_prompt`、`post_history_instructions`；
- `mes_example`、`alternate_greetings`、`depth_prompt`；
- 未知 extensions、采样参数、模型参数和 CharX/BYAF 脚本资源。

不要把角色卡正则脚本转换成现有 `AssistantRegex`。历史推理过滤是 Kelivo
原生、固定的上下文构建规则，不依赖角色卡正则。

## 实施顺序

严格按实施计划阶段 0 至阶段 6 执行。每一阶段完成后都要：

1. 汇报修改文件和行为；
2. 运行该阶段聚焦测试；
3. 报告真实结果；
4. 修复本阶段新增失败后再进入下一阶段。

不要先铺设大量 UI 再补底层。必须先完成纯解析和安全转换测试，再接存储和
界面；推理过滤必须先完成内联标签，再单独处理结构化推理和提供商兼容。

## 关键实现约束

### 角色卡与助手

- 首版不创建独立 CharacterCard 库；导入直接创建 RP Assistant。
- 扩展 Assistant 的 JSON、copyWith、复制、Provider、备份、验证和设置合并。
- 旧数据缺少新字段时无损加载，普通助手默认不过滤历史推理。
- PNG 元数据优先 `ccv3`，再回退 `chara`，按 Base64 UTF-8 JSON 解码。
- 使用结构化 PNG chunk 解析，不扫描二进制字符串猜测 JSON。
- 限制文件大小、chunk 大小和解析资源；解析失败不保存半成品。
- 头像复制到现有管理目录，沿用现有删除和复制规则。
- 用脱敏 fixture；不要提交用户下载的真实角色卡。

### 内嵌世界书

- 复用当前 `WorldBookImportService`、Provider 和每助手 active IDs。
- 角色卡内嵌导入使用单独安全策略，不改变独立世界书导入行为。
- 普通关键词条目按当前支持字段转换。
- regex-only 条目保留正文但默认禁用；混合关键词只使用普通关键词并警告。
- 依赖当前不能正确表达的高级条件时默认禁用，不能静默扩大触发范围。
- 为书和条目生成新 UUID，保存后绑定 RP 助手；失败时清理半成品。
- 导入 UI 明确显示启用、禁用、跳过和忽略统计。

### 开场白与提示词

- `first_mes` 是新对话第一条真实 assistant 消息，不是每轮 system 注入。
- 对同一 conversation ID 不得因为重建、重试、重启或切换而重复插入。
- 人物设定作为独立 system 规范消息，增加
  `ContextSource.characterPrompt`。
- 系统提示词、人物设定、世界书、提示词预设和真实历史的顺序按计划实现并
  测试，不得把人物设定写回 systemPrompt。
- 只安全展开 `{{char}}` 和 `{{user}}`；未知宏保留原文，不执行代码。

### 历史推理过滤

目标行为必须精确满足：

```text
界面显示           不变
本地消息和推理数据 不变
以后每次发送上下文 已完成历史只包含最终正文
同一轮工具续接     保持合法
```

- 复用 `ThinkingTagParser` 产生发送副本的 `visibleContent`，不要复制一套标签
  正则，也不要修改 persisted ChatMessage。
- 在世界书扫描和上下文裁剪之前过滤，保证思考不会触发世界书或占用裁剪预算。
- 对开启开关的助手，每次构建 API 消息都重新过滤所有历史 assistant 消息，
  因而第 2、3、10 轮都不能重新带回第 1 轮思考。
- 过滤 `reasoning_content` 和 `reasoning_details` 中的可读推理，不能只处理
  `<think>` 文本。
- 使用现有 `processingMessageId` 或等价的明确状态保护当前模型轮次。Kimi、
  GLM、OpenRouter、Claude 等当前工具调用依赖的 reasoning echo 不得被提前
  删除。
- Claude 已完成历史中的 thinking blocks 可过滤，但必须保留 tool_use、
  tool_result 和文本顺序。
- Gemini `thoughtSignature` 是协议制品；只有确认不需要时才能删除。保留必要
  签名不算违反“只删除可读推理正文”。
- 不用字符串正则改写签名或结构化 JSON。
- 过滤后正文为空时按 API 约束安全处理，不能生成非法空消息、孤立 tool result
  或错误角色序列。
- 给 Context Logger 测试增加断言，确认记录的是实际发送长度和内容来源。

## 必须运行的聚焦测试

测试文件名可以适应现有目录，但必须覆盖实施计划第 13 节。至少单独运行：

```powershell
flutter test test/features/character_card
flutter test test/features/home/services/message_builder_roleplay_test.dart
flutter test test/features/home/services/message_builder_thinking_filter_test.dart
flutter test test/features/world_book
flutter test test/core/providers/prompt_preset_provider_test.dart
flutter test test/features/home/services/message_builder_prompt_preset_test.dart
```

如果实际测试路径不同，列出等价命令。特别复跑仓库现有的 Kimi、GLM、
OpenAI reasoning details、Claude history 和 Gemini function calling 测试；不要
为了让新测试通过而削弱这些兼容测试。

最终执行：

```powershell
dart format lib test
flutter gen-l10n
dart analyze --fatal-infos lib test
flutter test
```

不得用宽泛 catch、跳过测试、删除断言或降低 analyzer 规则掩盖问题。完整测试
如遇 `AGENTS.md` 已记录的历史失败，给出具体测试、错误和与本功能无关的证据；
所有新增和受影响测试必须通过。

## 手动验收

至少完成以下场景：

1. 导入最小 V1、V2/V3 JSON 和带 `chara`/`ccv3` 的 PNG；
2. 导入后助手名称、头像、人物设定和开场白正确；
3. 新对话显示一次开场白，关闭重开和重启不重复；
4. 内嵌世界书自动绑定，普通关键词触发；
5. 正则脚本和插件内容没有进入任何执行路径；
6. 高级/正则世界书条目按报告禁用；
7. RP 助手同时使用现有提示词预设时 role 和前后顺序正确；
8. 模型回复含 Kelivo 识别的思考标签时，界面仍按原方式展示；
9. Context Logger 显示下一轮及更远轮次只发送最终正文；
10. 开关关闭后恢复当前历史发送行为；
11. 至少一次带工具调用的推理模型续接成功；
12. 普通助手、世界书、快捷指令、快捷回复和附件没有回归。

## APK 交付

只交付 Release APK。按照 `AGENTS.md` 在 ASCII 路径
`E:\devtools\kelivo-apk-build` 构建，必要时使用指定 JDK 17 和本机现有个人
测试签名：

```powershell
flutter build apk --release
```

设备或模拟器可用时使用 `adb install -r`，完成启动、键盘、角色卡文件选择、
新对话开场白、世界书、多轮上下文过滤和工具调用冒烟测试。不得提交签名文件
或 `android/key.properties`。

最终回复必须包含：

- 实现结果和关键设计；
- 修改文件分类摘要；
- 角色卡支持/忽略字段清单；
- 世界书转换统计与限制；
- 内联和结构化推理过滤行为；
- 提供商工具续接验证结果；
- 聚焦测试、analyzer 和完整测试的真实结果；
- 手动测试结果；
- Release APK 绝对路径、文件大小和 SHA-256；
- 未实现项和残余风险；
- `git status --short --branch`。

完成实现、验证和 APK 后等待用户决定是否提交或推送。
