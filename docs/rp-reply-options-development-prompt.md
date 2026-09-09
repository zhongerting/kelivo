# 新对话实施 Prompt：RP 剧情选项栏

请在 `E:\杂项\chatbox\kelivo` 中完整实现并测试“RP 剧情选项栏”。这不是方案讨论任务，需要完成生产代码、自动化测试、Android Release APK 和模拟器验收。

开始前必须完整阅读：

- `AGENTS.md`
- `docs/rp-reply-options-implementation-plan.md`

先运行 `git status --short --branch`、查看最近提交并记录修改前测试基线。工作树可能包含用户改动，必须保留并与其协作；不得执行 reset、checkout、clean、stash、commit、push 或任何远端写操作。

## 产品边界

1. 剧情选项由当前聊天主模型与正文在同一次回复中生成。不得发起第二次建议生成请求。
2. 新功能完全独立于旧“聊天建议模型”：不得调用 `ChatSuggestionService`，不得复用 `Conversation.chatSuggestions`，不得受 `suggestionInsertOnTapOnly` 控制。旧功能及其测试保持原样，用户会保持它关闭。
3. 本阶段不创建选项世界书内容。Kelivo 只实现固定协议、解析、持久化、UI、上下文隔离和交互；后续另行设计世界书提示词。
4. 不导入或执行 SillyTavern regex_scripts、JavaScript、HTML、iframe、slash command、Tavern Helper 或未知插件。选项永远是纯文本。

## 固定协议

Kelivo 只识别以下结构，世界书之后会要求模型把它放在回复正文末尾：

```text
正常正文

<kelivo_options>
<option>选项一</option>
<option>选项二</option>
</kelivo_options>
```

新增专用、有界、无灾难性回溯风险的解析器。不要把用户可配置的 `AssistantRegex` 作为核心机制。最终解析执行 trim、删除空项、精确去重，只保留前 6 项。无标记时保持原正文。检测到起始标记但块未闭合或无效时不生成选项，同时确保标记尾部不会进入模型上下文。流式解析必须基于累计文本并正确处理标签跨 chunk；正文照常流式显示，选项只在回复完成且解析成功后一次性出现。

## 数据模型

优先在现有 `MessagePart` 体系新增 `ReplyOptionsPart`，kind 使用 `reply_options`，payload 使用结构化 JSON，例如：

```json
{"version":1,"assistantId":"assistant-id","options":["选项一","选项二"]}
```

对 payload 做严格验证并补充 encode/decode、非法 payload 和 JSON round-trip 测试。选项必须保存到具体 assistant `ChatMessage.id`，从而绑定具体回复版本。不要添加 conversation 级选项字段。

先核对 `message_part_rows` 是否允许任意 kind/payload。预计可以复用现有表而不迁移 schema，但必须用 Drift round-trip 和备份恢复测试证明，不能凭假设跳过验证。`ChatMessage.content` 必须继续只由正文 TextPart 组成。

`ReplyOptionsPart` 保存生成时的 assistantId。面板只显示当前 conversation、当前选中回复版本、当前 assistantId 对应的选项。切换助手后旧助手选项立即隐藏。

## 流式接入

重点检查 `chat_actions.dart` 中 `StreamingState.fullContentRaw`、`_transformAssistantContent`、`_assistantPartsForState`、`_publishAssistantParts`、`scheduleThrottledUpdate` 和 `_finishStreaming`。

- Provider 原始 chunk、reasoning、tool calls、images、files 和 provider artifacts 继续走原流程。
- 流式发布到 `StreamingContentNotifier` 前，对累计正文应用 streaming parse，只发布可见正文。
- 不得在每个 token 上更新 HomePage 级选项状态或重建输入框。
- `_finishStreaming` 中对最终 assistant TextPart 做一次 final parse，剥离选项块，并加入一个 `ReplyOptionsPart` 后再持久化。
- 回复可能包含由工具调用分隔的多个 TextPart。移除选项尾部时必须保持所有 ReasoningPart、ToolCallPart、ImagePart、FilePart 及文本 part 的原 ordinal，不能粗暴地把所有正文折叠到第一个 TextPart。
- 检查取消、错误、工具续接、streaming checkpoint 和恢复路径，保证未完成选项块不泄漏、最终解析不重复插入 part。

## 当前选项选择器

从当前 conversation 的折叠版本消息派生选项：最后一条有效消息必须是已完成 assistant 消息、包含有效 ReplyOptionsPart、part.assistantId 与当前助手一致，并且当前不在对话/助手切换、消息选择或发送占用状态。

不要为了“清空”而删除历史 ReplyOptionsPart。用户发送后，原 assistant 不再是最后一条消息，面板自然隐藏；发送 rejected 且没有追加消息时原选项继续显示。重新生成和切换版本时，根据 `versionSelections` 显示该 revision 自己的选项。删除 revision/conversation 时依赖现有 part 级联清理。

切换 conversation 时先隐藏旧面板，再加载目标消息；加载完成后只显示目标 conversation 最新选中 assistant revision 的选项，绝不能闪现上一对话数据。全局保存展开/收起偏好，但切换动作不能改写该偏好。

## UI 与布局

在输入框上方新增独立 `ReplyOptionsPanel`。无选项时不占高度；收起时显示固定高度 header、“选项”、数量和右侧 lucide chevron；展开后显示最多 6 行、限高且可内部滚动的列表。每行主体点击直接发送，右侧有独立“追加”按钮，不能发生事件冒泡。补齐 ARB 本地化、Semantics 和移动端触控尺寸。

保留 `_inputBarKey` 作为真实 ChatInputBar 的测量/弹层锚点，避免快捷短语、MCP、世界书等 popover 错位。新增组合底部浮层 key/高度，供消息列表 bottomContentPadding、滚动按钮 bottomOffset、编辑遮罩 bottomInset 等避让“选项栏 + 输入框”。Android 键盘出现时不能重建 TextEditingController、附件控制器或背景图。

展开状态通过 `SettingsProvider` 独立布尔键持久化，例如 `reply_options_expanded_v1`。面板只在 final reply 到达时出现，不监听 token 级状态。

## 发送和追加

新增 `sendReplyOption`，不要复用受旧设置影响的 `sendSuggestion`。直接发送时构造独立 `ChatInputData(text: option)` 并走正常 send path；不得读取、替换或清空当前 `_inputController`，不得领取或清空当前附件。复用发送占用和双击保护。只有 sent/queued 后面板才因消息推进而隐藏，rejected 时保持可用。

从快捷短语实现中提取通用的 selection 插入 helper。点击“追加”时在有效光标处插入、替换选区或在 selection 无效时追加到末尾，更新 collapsed selection，清空 composing range，下一帧恢复输入焦点；不发送、不清空选项、不修改附件。不要自动添加空格或换行。

## 上下文隔离

逐条审计正常聊天、工具续接、`MessageGenerationService`、`MessageBuilderService`、`ModelVisibleHistory`、上下文压缩、记忆、标题、旧聊天建议 buildContent、Context Logger 和所有 provider part serializer。所有模型可见路径只能读取正文 TextPart，不得序列化 ReplyOptionsPart、`kelivo_options` 标记或选项文本。

不要重新设计已完成的历史思考过滤。必须继续保留当前 processingMessageId 所需 reasoning、tool calls、tool results、Claude thinking/tool blocks、Gemini thoughtSignature 及 Kimi/GLM/OpenRouter 协议数据。备份恢复保留 ReplyOptionsPart，普通聊天导出只输出正文和现有可见内容，不输出内部协议标记。

## 必须测试

- parser：无标记、空块、1/6/超过6项、空项、重复项、中文、多行、跨 chunk、部分起始标签、未闭合和无效格式。
- 组合：inline think + options、结构化 reasoning/tools + options、图片/文件 part + options。
- persistence：MessagePart JSON、Drift、临时对话、备份恢复、重启、旧数据。
- version：重新生成、版本切换、版本删除、conversation 删除。
- UI：无选项零高度、展开/收起持久化、限高滚动、窄屏/平板/桌面、键盘不重叠。
- actions：直接发送保留草稿附件、double tap 只发送一次、rejected 保留选项、追加光标/选区/焦点、追加按钮不冒泡。
- lifecycle：对话切换不闪旧数据、目标对话恢复自己的选项、助手切换隐藏旧选项。
- context：聊天、压缩、记忆、标题、旧建议构建和 Context Logger 均无标记及选项内容。
- providers：Kimi、GLM、OpenAI reasoning、OpenRouter tools、Claude、Gemini 协议回归。

## 验证和交付

先运行新增及受影响聚焦测试，再运行：

```bash
flutter gen-l10n
dart format lib test
dart analyze --fatal-infos lib test
git diff --check
flutter test
```

记录修改前后全量结果，区分新增失败和 Windows 文件锁、临时目录、缺失 plugin 等既有基线失败。任何角色选项、上下文或 provider 协议相关失败都必须修复，不得以环境问题掩盖。

将已测试源码同步到 `E:\devtools\kelivo-apk-build`，使用 `E:\devtools\temurin-17\jdk-17.0.20.1+1` 的 JDK 17 构建 `flutter build apk --release`。安装到模拟器，手动验收正文流式、标签不闪现、选项完成后出现、展开收起、直接发送、追加、草稿附件、对话/助手/版本切换、重启恢复和 Context Logger 实际发送正文。

最终报告：主要修改文件、协议和降级规则、数据迁移结论、聚焦/全量测试、基线差异、手动验收、残余风险、APK 绝对路径、大小、版本、versionCode 和 SHA-256。保持所有工作为未提交状态，不执行 commit 或 push，等待用户决定。
