# RP 剧情选项实现方案

## 1. 目标

在 Kelivo 中增加一套独立于现有“聊天建议模型”的 RP 剧情选项能力。当前聊天主模型在一次回复中同时生成正文和若干选项，Kelivo 将两者解析为不同的数据：正文照常显示并进入后续上下文，选项绑定到本次 assistant 回复版本，只显示在输入框上方的选项栏中，永远不进入任何模型可见上下文。

本功能不调用 `ChatSuggestionService`，不读取或写入 `Conversation.chatSuggestions`，也不改变“设置 -> 默认模型 -> 聊天建议模型”的现有行为。用户保持该旧功能关闭。

本阶段不编写“选项世界书”的具体提示词，只规定 Kelivo 支持的输出协议。后续世界书负责要求模型遵守该协议。

## 2. 固定输出协议

主模型输出格式如下：

```text
这里是正常的剧情正文。

<kelivo_options>
<option>调查房间里传来的声音</option>
<option>询问对方刚才隐瞒的事情</option>
<option>暂时离开这里</option>
</kelivo_options>
```

协议约束：

- 一个回复最多包含一个 `kelivo_options` 块，并要求放在正文末尾。
- 每个选项使用一个无属性的 `option` 元素。
- 选项是纯文本，不渲染或执行 HTML、JavaScript、iframe、slash command、Tavern Helper 或任何插件内容。
- 解析后对选项执行 `trim`、删除空项、按规范化后的完整文本去重，只保留前 6 项。
- 正文中不存在起始标记时，整个回复按普通正文处理。
- 流式阶段一旦识别完整的起始标记，界面正文只显示标记之前的内容。
- 回复结束时如果块未闭合、没有有效选项或格式无效，不创建选项数据；从已识别起始标记开始的尾部仍不得进入模型上下文。
- 解析器应设置合理的总块大小保护，避免异常模型输出导致无界内存或布局开销，但正常的 6 个文本选项不应被截断。

不要使用通用助手正则承担核心解析。现有 `AssistantRegex` 只负责字符串替换，不能表达选项列表、消息版本归属和持久化语义。可以在专用解析器内部使用受控的 `RegExp` 查找标签，但协议和行为必须由应用代码固定。

## 3. 解析器设计

建议新增 `lib/core/utils/reply_options_parser.dart`，提供两个明确入口：

```dart
ReplyOptionsStreamingView parseStreaming(String rawText);
ReplyOptionsParseResult parseFinal(String rawText);
```

建议结果至少包含：

```dart
class ReplyOptionsParseResult {
  final String body;
  final List<String> options;
  final bool markerDetected;
  final bool valid;
}
```

`parseStreaming` 只负责计算当前可见正文，不发布选项。它必须正确处理标签被拆在多个网络 chunk 中的情况，例如 `<keli` 与 `vo_options>` 分两次到达。不能只对单个 chunk 做正则；必须针对累计文本解析。

`parseFinal` 在回复完成后执行一次，产出最终正文和最多 6 个选项。解析算法应是有界、确定性的单次或少量扫描，避免对很长回复使用灾难性回溯正则。测试必须覆盖中文、多行、空白、重复项、超出 6 项、未闭合外层标签、未闭合 `option` 标签和正文中没有协议标记。

## 4. 数据模型与持久化

### 4.1 新的 MessagePart

优先在 `lib/core/models/message_part.dart` 中新增 `ReplyOptionsPart`：

```dart
final class ReplyOptionsPart extends MessagePart {
  final int version; // 当前协议版本固定为 1
  final String assistantId;
  final List<String> options;

  @override
  String get kind => 'reply_options';
}
```

payload 使用结构化 JSON，而不是拼接字符串：

```json
{"version":1,"assistantId":"assistant-id","options":["选项一","选项二"]}
```

`MessagePart.fromRow` 增加 `reply_options` 分支，并对 payload 类型、协议版本、assistantId 和 options 数组做严格验证。未知 part 仍维持现有 `UnknownPart` 行为。

### 4.2 为什么不放进 ChatMessage.content

`ChatMessage.content` 当前只连接 `TextPart`。让选项进入 `ReplyOptionsPart` 后可以获得以下保证：

- 后续聊天历史读取正文时自然看不到选项。
- 选项与具体 `ChatMessage.id` 绑定，因此自动绑定具体回复版本。
- Drift 的 `message_part_rows` 已按 `revision_id + ordinal` 保存任意 kind/payload，预计不需要新增数据库列；实施时仍须检查约束并用 round-trip 测试确认。
- `ChatMessage.toJson/fromJson` 和备份可以通过通用 part 序列化保存选项。
- 老版本 Kelivo 会把无法识别的 `reply_options` 保留为 `UnknownPart`，不会误拼入正文。

不要增加 conversation 级选项字段，也不要复用 `chatSuggestions`，否则回复版本切换时会发生正文与选项错配。

### 4.3 对 assistantId 的处理

`ReplyOptionsPart.assistantId` 记录生成该回复时使用的助手。底部面板只在 part 中的 assistantId 与当前对话助手一致时显示。切换助手后旧选项立即隐藏；切回原助手时是否恢复由“当前选中的最新 assistant 回复是否仍然有效”这一统一选择规则决定，不复制选项数据。

## 5. 流式生成链路

当前流式主链位于 `chat_actions.dart`：累计文本进入 `StreamingState.fullContentRaw`，`_transformAssistantContent` 负责持久化正则，`_publishAssistantParts` 和 `scheduleThrottledUpdate` 向消息气泡发布内容，`_finishStreaming` 最终构造并保存 `finalizedMessage`。

建议接入顺序：

1. Provider chunk 仍照常写入 `partsHandler` 和 `fullContentRaw`，不要修改协议适配器或工具调用数据。
2. 在发布流式正文前，对累计且完成 persist-regex 处理的文本调用 `parseStreaming`，只把 `body` 交给 `StreamingContentNotifier`。
3. 不要在每个 chunk 上更新 HomePage 级的选项状态；这会造成输入框及底部布局频繁重建。流式期间底部选项栏保持隐藏或保持上一状态已经被发送流程清除后的空状态。
4. `_finishStreaming` 中先生成并清理 assistant parts，再对最终 TextPart 文本执行 `parseFinal`。
5. 保留所有 `ReasoningPart`、`ToolCallPart`、`ImagePart`、`FilePart` 和 provider artifacts 的原顺序，只移除 TextPart 中属于选项块的尾部。
6. 把有效选项作为一个 `ReplyOptionsPart` 附加到 finalized message，然后一次性持久化和发布。
7. `onAssistantMessageFinished` 之后 HomePage 根据最终消息刷新选项面板，不再发起第二次生成请求。

因为一条回复可能包含被工具调用分隔的多个 TextPart，不能简单地把所有正文塞进第一个 TextPart。协议要求选项块位于最终文本尾部，可以根据聚合文本中的 `bodyEndOffset` 逐个遍历 TextPart，保留截止偏移量之前的文本并保持所有非文本 part 的 ordinal 顺序。

取消、网络错误、工具续接和恢复中的 streaming checkpoint 也要审计：未完成的选项块不能作为正文重新进入下一次请求。恢复完成后的正常终结路径应再次运行最终解析，且不得重复添加 `ReplyOptionsPart`。

## 6. 当前可用选项的选择规则

建议把“当前可用选项”定义为一个纯派生选择器，而不是复制到 HomePage 临时列表：

1. 读取当前 conversation。
2. 按 `versionSelections` 折叠消息版本。
3. 要求折叠后的最后一条有效消息是已完成的 assistant 消息。
4. 该消息必须包含有效 `ReplyOptionsPart`。
5. part.assistantId 必须等于当前 conversation/assistant 的有效 assistantId。
6. 当前不能处于对话切换中、助手切换中、消息选择模式或发送占用状态。

直接发送或手动发送会立即追加 user 消息或 streaming assistant 占位消息，原 assistant 不再是最后一条有效消息，因此选项自然消失，不必删除历史 part。若发送被拒绝且没有追加消息，原选项继续显示。

重新生成产生新的 assistant revision 和新的 `ReplyOptionsPart`。切换版本时，选择器根据 `versionSelections` 自动显示对应版本的选项。删除回复版本时，数据库级联删除其 part。

切换 conversation 时，先将切换状态置为 true 并隐藏旧面板，再加载目标窗口；加载完成后只从目标 conversation 重新派生。这样不会出现上一对话选项短暂闪现。

## 7. 底部 UI 与布局

建议新增 `ReplyOptionsPanel`，放在 `ChatInputOverlayLayout.bottomOverlay` 中，与 `ChatInputSection` 组成一个 `Column`：

```text
Expanded panel: 选项列表（限高、内部滚动）
Header:        选项  3                         [chevron]
ChatInputBar:  原输入框
```

UI 约束：

- 无当前选项时整个 panel 不占高度。
- 收起时仅显示稳定高度的 header；展开/收起使用箭头图标，不使用文字按钮。
- 展开列表最多 6 行，达到最大高度后内部滚动，不允许无限推高消息区。
- 每行主体区域点击直接发送，右侧“追加”是独立 hit target，不能冒泡触发发送。
- 使用 `lucide_icons_flutter`、现有 tactile/button 组件、主题色和 ARB 本地化。
- Android 触控区域至少满足 44-48 logical pixels，长文本换行或省略，不能压住“追加”。
- 面板只在回复完成后重建一次，不能监听每个流式 token。

当前 `_inputBarKey` 同时承担真实输入框测量和多个 popover 的锚点。不要直接把它移动到包含选项面板的外层，否则快捷短语、MCP、世界书等弹层的锚点会移动到面板顶部。建议保留 `_inputBarKey` 给真实输入框，另增 `_bottomOverlayKey` 测量“选项栏 + 输入框”的组合高度。

把消息列表 `bottomContentPadding`、滚动导航按钮 `bottomOffset`、编辑遮罩 `bottomInset` 等需要避让底部浮层的位置改用组合高度。键盘出现时仍由现有 `ChatInputOverlayLayout` 处理，不重建背景图或输入控制器。

展开状态使用 `SettingsProvider` 中一个独立布尔偏好，例如 `reply_options_expanded_v1`。它只保存用户偏好，不保存选项内容。对话切换时可以暂时隐藏内容，但不能改写该偏好；目标对话加载后按照同一偏好展开或收起自己的选项。

## 8. 发送与追加

### 8.1 直接发送

- 新增独立的 `sendReplyOption`，不要复用 `sendSuggestion`，后者受旧的 `insertSuggestionOnTapOnly` 设置影响。
- 构造新的 `ChatInputData(text: option)` 并走正常 `sendMessage` 路径。
- 不读取、不清空、不替换 `_inputController`，也不领取 `_mediaController` 中的附件，因此原草稿和附件保持原状。
- 复用现有 conversation send-in-flight guard，按钮在请求被占用后立即禁用，防止双击生成两组消息。
- 只有返回 `sent` 或 `queued` 后才认为操作成功；`rejected` 时继续显示原选项。

### 8.2 追加

- 从 `handleQuickPhraseSelection` 中提取可复用的“按当前 selection 插入文本”私有帮助函数。
- selection 无效时在文本末尾插入；存在选区时替换选区；插入后把光标置于新文本末尾并清空 composing range。
- 下一帧恢复 `_inputFocus`。
- 不发送消息、不修改附件、不隐藏选项。

是否自动加空格或换行不应由 UI 猜测；默认原样插入选项文本，由世界书决定选项自身格式。

## 9. 模型上下文隔离

结构化 part 是第一道保证，但仍需逐条审计所有模型可见入口，确认它们是白名单读取 TextPart，而不是遍历并字符串化未知 part：

- 正常聊天和工具续接：`MessageGenerationService`、`MessageBuilderService`。
- 历史思考过滤：`ModelVisibleHistory`，保持现有行为，不重构。
- 上下文压缩。
- 记忆提取和记忆更新。
- 标题生成。
- 现有聊天建议服务，即使用户保持关闭也不得把 `ReplyOptionsPart` 拼入内容。
- Context Logger 的实际请求快照。

发送给 provider 的 assistant 正文必须等于解析后的 TextPart 内容。保留当前 processingMessageId 所需的 reasoning、tool calls、tool results、Claude thinking/tool blocks、Gemini thoughtSignature 和 OpenRouter/Kimi/GLM 协议制品。选项过滤不能通过“把整个 assistant parts 重建成一个字符串”破坏这些结构。

备份应保留 `ReplyOptionsPart` 以便恢复；面向人的普通聊天导出默认只导出正文，不输出内部协议标记。若已有原始诊断导出，则可以保留结构化 part，但不得把它伪装成正文。

## 10. 与旧聊天建议的边界

新剧情选项和旧聊天建议是两个独立功能：

- 新功能不读取 `isSuggestionGenerationEnabled`。
- 新功能不调用 `_maybeGenerateSuggestionsFor` 或 `ChatSuggestionService.generate`。
- 新功能不写入 `Conversation.chatSuggestions`。
- 旧功能的气泡、设置、数据和测试保持原样。
- 用户保持旧功能关闭，因此正常运行时不会发生第二次 API 请求。

不要为了新功能删除旧代码，也不要把两个列表合并成同一个状态。测试应证明启用协议解析不会触发旧建议服务。

## 11. 测试矩阵

### 11.1 解析器

- 无标记、空块、1 项、6 项、7 项及更多。
- 空项、重复项、首尾空白、中文、标点和多行文本。
- 标签跨 chunk、起始标签部分到达、完整外层但内部标签损坏、外层未闭合。
- 正文包含 `<think>` 与选项块；思考过滤和选项过滤互不覆盖。
- 选项文本包含看似 Markdown、HTML 或 slash command 的内容，只作为普通字符串返回。

### 11.2 数据与版本

- `ReplyOptionsPart` payload encode/decode、非法 payload 分类、ChatMessage JSON round-trip。
- Drift message part round-trip、临时对话、备份恢复、应用重启。
- 回复重新生成、版本切换、版本删除和 conversation 删除。
- 旧数据库没有 `reply_options` 时行为不变。

### 11.3 上下文

- 普通下一轮请求只包含正文。
- 上下文压缩、记忆、标题和现有建议 buildContent 看不到选项。
- Context Logger 快照中不出现 `kelivo_options`、`reply_options` 或选项文本。
- Kimi、GLM、OpenAI reasoning details、OpenRouter tools、Claude blocks、Gemini function calling/thoughtSignature 回归。

### 11.4 UI 和交互

- 无选项不占高度；收起和展开高度正确；最多显示 6 项。
- 展开偏好持久化，重启后恢复。
- 对话切换期间旧选项不闪现；目标对话只显示自己的选项。
- 助手切换隐藏旧选项。
- 直接点击发送一次，双击不重复；发送失败时选项仍在。
- 直接发送保留已有草稿和附件。
- “追加”不触发行点击，在光标插入或替换选区，附件不变并恢复焦点。
- 键盘打开、横竖屏、窄屏、平板和桌面不重叠。
- 流式期间正文正常更新，标签和选项从未出现在聊天气泡里，选项只在完成后出现一次。

## 12. 验证与交付

先运行聚焦测试，再运行：

```bash
flutter gen-l10n
dart format lib test
dart analyze --fatal-infos lib test
git diff --check
flutter test
```

全量测试需要与修改前 Windows 基线比较，不能把文件锁、临时目录和缺失插件等既有失败误报为本功能通过，也不能忽略新增失败。

Android 性能验收必须使用 Release APK。将已测试源码同步到 ASCII 路径 `E:\devtools\kelivo-apk-build`，使用 JDK 17 执行 `flutter build apk --release`，随后在模拟器完成冷启动、键盘、流式显示、展开收起、直接发送、追加、对话切换、助手切换、版本切换和重启恢复。最终报告 APK 路径、大小、版本、versionCode 和 SHA-256。

本任务完成前不得 commit、push 或修改远端，等待用户审查。
