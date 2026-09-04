# Kelivo 历史思考上下文过滤补全计划

## 1. 结论

该需求可以实现，而且当前工作树已经完成主要路径：聊天界面、数据库、备份和
导出保留完整回复；下一轮普通聊天请求只使用过滤后的临时副本。现有实现还会
保留当前 `processingMessageId`、工具调用/结果、Claude 工具块、Gemini
`thoughtSignature` 和必要的加密/签名制品。

但审计发现，若把“后续上下文”定义为所有会把历史发送给模型的路径，当前仍需
补齐：

1. 手动“压缩上下文”直接读取历史 `message.content`；
2. 聊天建议生成直接读取最近的 user/assistant 消息；
3. 记忆管线的 gatekeeper/extractor 直接构造完整对话文本；
4. 标题生成已过滤内联思考，但应改为复用统一策略，避免未来行为分叉。

自动会话摘要当前只读取用户消息，不包含 assistant 思考，可保留现状，但必须有
审计测试证明这一点。

## 2. 产品语义

- 开关：继续使用助手字段 `excludeThinkingFromContext`。
- RP 角色卡导入助手默认开启；旧助手和普通助手默认关闭，用户可以手动开启。
- 开启后，只过滤“已完成的历史 assistant 消息”。
- 当前仍在生成或工具续接的 assistant 消息必须保持协议完整。
- 过滤只作用于即将发送给模型的副本，不修改 `ChatMessage`、数据库、界面、备份、
  导出、翻译或原始推理记录。
- 可识别内容包括现有 `ThinkingTagParser` 支持的内联思考标签，以及请求消息中的
  `reasoning_content`、`reasoning`、可读 `reasoning_details` 和 Claude thinking
  blocks。
- 未带标签、与正文混在一起的普通文本无法可靠判断是否为思考，不做猜测删除。
- 本功能节省的是后续请求重复携带历史思考的 token；第一次生成思考所消耗的
  token 不会被追回。

## 3. 统一过滤策略

建立或整理一个无 UI 依赖的纯过滤入口，复用现有 `ThinkingTagParser` 的解析能力，
不要在压缩、建议、记忆和标题路径分别复制正则。

统一入口至少提供：

1. 根据 assistant 开关、消息角色和状态返回“模型可见正文”；
2. 对历史 assistant 的内联思考返回 `visibleContent`；
3. user/system/tool 内容保持不变；
4. 纯思考且没有工具/协议载荷的历史 assistant 消息可以从请求副本移除；
5. 原始 `ChatMessage` 和 `MessagePart` 不得被修改；
6. API Map 的结构化推理过滤继续复用现有实现，不把签名字段当成可读思考删除。

如果需要移动 `ThinkingTagParser`，应移动到 core/shared 的非 UI 层并更新现有导入；
不要让 `lib/core/` 新增对 `lib/features/` 的反向依赖。若无需移动即可通过回调注入
纯文本转换，则优先选择改动较小的方案。

## 4. 接入顺序

### 4.1 普通聊天请求

复核并保留 `MessageGenerationService` 当前顺序：

1. 从持久化消息构建 API 副本；
2. 过滤已完成历史的内联和结构化思考；
3. 再进行正则替换、世界书扫描、上下文裁剪和附件处理；
4. 最后移除内部 message ID 并发送。

必须保证被删除的思考不会触发世界书关键词，也不会占用上下文裁剪预算。

### 4.2 压缩上下文

在 `HomeViewModel.compressContext` 生成摘要请求内容前，对 `summarizeInput` 应用同一
文本策略。过滤必须只影响发送给压缩模型的文本：

- `collapsed`、`keptMessages` 和原会话不变；
- keep-recent 模式复制到新会话的历史消息仍保留完整 UI 内容；
- 分块长度和 token/字符预算基于过滤后的文本；
- 纯思考历史不生成空的 `Assistant:` 段落；
- 生成的摘要不会重新携带已过滤思考。

### 4.3 聊天建议

为 `ChatSuggestionService.buildContent/generate` 提供模型可见内容转换能力，由当前
助手开关控制。最近消息选择、truncateIndex、数量和字符限制保持原逻辑，但字符
限制应作用于过滤后的文本。

### 4.4 记忆管线

在 `MemoryPipelineService` 构造 gatekeeper/extractor 的 conversation text 时使用同一
过滤策略。窗口选择、watermark、失败重试和消息计数仍基于原消息，只有发送给
记忆模型的对话文本改变。避免因为纯思考消息被过滤而破坏 watermark 推进。

### 4.5 标题和其他路径

标题生成和侧栏标题已经过滤内联思考，应改为复用统一入口。继续审计所有
`loadMessages/allMessagesForCurrentConversationContext -> ChatApiService.generateText`
路径；逐项记录“需要接入”或“只读取用户消息/不属于上下文，因此无需接入”。

## 5. 协议安全边界

- 当前 `processingMessageId` 整条保留，确保同轮工具续接合法。
- 历史 `tool_calls`、tool result 和文本顺序保留。
- 删除 Claude 已完成历史中的可读 thinking/redacted thinking block 时，保留 tool_use
  及对应结果。
- Gemini `thoughtSignature`、OpenRouter/OpenAI 的必要 opaque signature、encrypted
  payload 等继续保留。
- 不将结构化对象字符串化后再用正则清理。
- 遇到未知或损坏的协议结构时采取保守策略并记录测试，不能静默破坏工具链。

## 6. 测试计划

### 6.1 纯过滤和普通聊天

- 多个、大小写混合、未闭合和纯思考标签；
- 过滤开关关闭时完全不变；
- 数据库对象与请求副本隔离；
- reasoning 字段、Claude blocks 和 Gemini signature；
- 当前 processing turn 不过滤；
- 工具调用/结果配对不变；
- Context Logger 显示真正发送的正文和长度。

### 6.2 新增路径

- 压缩上下文捕获实际 prompt，断言无隐藏思考、正文存在、原消息未变；
- 压缩分块和预算基于过滤后长度；
- keep-recent 新会话保留原始可视消息，但以后发送时仍过滤；
- 建议生成 prompt 不包含历史思考，关闭开关时保留；
- 记忆 gatekeeper/extractor prompt 不包含历史思考，watermark 正常推进；
- 标题主路径和侧栏路径使用同一结果；
- 自动会话摘要只读取 user 消息的现有行为不变。

### 6.3 回归

运行现有角色卡、RP、世界书、提示词预设、Kimi、GLM、OpenAI、OpenRouter、Claude
和 Gemini 兼容测试。重点证明工具续接所需的签名和当前轮推理没有被删除。

## 7. 验证与交付

```powershell
flutter test test/features/home/services/message_builder_thinking_filter_test.dart
flutter test test/features/home/controllers/home_view_model_compress_context_test.dart
flutter test test/features/home/services/chat_suggestion_service_test.dart
flutter test test/core/services/memory
dart analyze --fatal-infos lib test
git diff --check
flutter test
```

实际测试文件名以仓库为准。Flutter 自动写入 `analysis_options.yaml` 的平台排除项
必须在最后用精确补丁清理。全量测试与现有 Windows 基线比较，不得掩盖新失败。

通过后重新同步到 `E:\devtools\kelivo-apk-build`，构建 Release APK，安装并用
Context Logger 验证普通续聊、压缩上下文和工具续接。记录 APK 路径、版本、大小、
SHA-256 和源码一致性。未经用户明确授权，不 commit、push 或创建 Release。
