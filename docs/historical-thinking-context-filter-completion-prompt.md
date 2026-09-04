# 交给 Kelivo 开发窗口的 Prompt：补全历史思考上下文过滤

请在 `E:\杂项\chatbox\kelivo` 中审计并补全“后续模型上下文不再携带历史思考”
功能。不要重新实现已经存在的主体；先确认当前实现，再只补齐遗漏路径，完成测试
和 Android Release APK 验证。

开始前完整阅读：

1. `E:\杂项\chatbox\kelivo\AGENTS.md`
2. `E:\杂项\chatbox\kelivo\docs\sillytavern-character-card-roleplay-implementation-plan.md`
3. `E:\杂项\chatbox\kelivo\docs\historical-thinking-context-filter-completion-plan.md`

先执行并汇报 `git status --short --branch`、`git diff --stat` 和
`git log -3 --oneline --decorate`。当前工作树包含未提交的角色卡、RP、世界书、
提示词预设和推理过滤工作；严禁 reset、checkout、clean、stash、切换分支或覆盖
用户改动。未经明确要求，不 commit、push、打标签或操作远端。

## 已有实现必须保留

- `Assistant.excludeThinkingFromContext`，旧/普通助手默认 false，导入 RP 助手默认 true；
- UI、数据库、备份和导出保留完整推理；
- `MessageGenerationService` 在 API 副本上过滤已完成历史；
- 内联标签、`reasoning_content`、`reasoning`、可读 `reasoning_details` 和 Claude
  thinking blocks 的过滤；
- 当前 `processingMessageId`、tool_calls/tool result、Claude tool blocks、Gemini
  `thoughtSignature` 和必要 opaque/encrypted 协议制品的保留；
- Context Logger 记录实际发送内容；
- 标题生成已有的内联过滤。

## 审计发现的待补齐路径

1. `HomeViewModel.compressContext` 当前直接使用历史 `message.content`；
2. `ChatSuggestionService` 当前直接拼接最近 user/assistant 内容；
3. `MemoryPipelineService` 当前直接用历史构造 gatekeeper/extractor conversation text；
4. 标题主路径和侧栏路径应复用统一过滤策略；
5. 审计其他 `loadMessages -> ChatApiService.generateText` 路径并逐项给出结论。

自动会话摘要目前只读取 user 消息，不要为了形式统一而改变它。

## 实施要求

建立或整理一个无 UI 依赖的纯“模型可见历史正文”入口，复用现有
`ThinkingTagParser`，不要在多个服务里复制正则。不得让 `lib/core/` 新增对
`lib/features/` 的反向依赖；如需移动解析器，放到 core/shared 并更新所有消费者。

接入以下路径：

- 普通聊天：保持过滤发生在世界书扫描和上下文裁剪之前；
- 压缩上下文：仅转换摘要请求副本，原消息和 keep-recent 消息不变，分块预算基于
  过滤后文本，纯思考历史不产生空 Assistant 段；
- 聊天建议：数量、truncateIndex 和字符限制不变，但 prompt 使用过滤后正文；
- 记忆管线：window/watermark 基于原消息，gatekeeper/extractor prompt 使用过滤后
  对话文本；
- 标题：主路径与侧栏复用同一入口。

只过滤已完成历史 assistant 的可读思考。user/system/tool 保持不变；无法识别的
无标签普通文本不猜测删除。当前处理中的 assistant turn 必须完整保留。所有转换
只作用于临时副本，不得修改 `ChatMessage`、MessagePart、数据库、UI、备份或导出。

## 必须新增或补强的测试

1. 普通续聊删除内联及结构化可读思考，原消息不变；
2. 开关关闭时所有路径保持原行为；
3. 当前 processing turn、工具调用/结果和协议签名完整；
4. 压缩模型实际 prompt 无历史思考，正文仍在，原消息和 retained messages 未变；
5. 压缩分块长度基于过滤后文本；
6. 建议模型 prompt 无历史思考；
7. 记忆 gatekeeper/extractor prompt 无历史思考，watermark 正常；
8. 标题主路径与侧栏结果一致；
9. reasoning-only 历史不产生空对话段；
10. Context Logger 与真正发送内容一致。

重跑现有 Kimi、GLM、OpenAI reasoning、OpenRouter tools、Claude history/tool blocks
和 Gemini function/thought-signature 测试。不得为通过测试删除断言、吞异常、修改
协议制品或扩大 analyzer 排除范围。

## 验证与 APK

至少运行现有 thinking filter、compress context、chat suggestion、memory pipeline、
角色卡、RP、世界书和提示词预设测试，然后执行：

```powershell
dart analyze --fatal-infos lib test
git diff --check
flutter test
```

Flutter 若自动修改 `analysis_options.yaml`，全部命令结束后仅用精确补丁清理自动
新增的平台排除项。全量失败必须与当前 Windows 基线比较，不能把新增功能失败归为
环境问题。

验证完成后，把已测试源码同步到 `E:\devtools\kelivo-apk-build`，比较运行时源码
一致性，构建 `flutter build apk --release`，在模拟器安装并冷启动。使用 Context
Logger 手动验证：普通续聊不发送历史思考、压缩上下文不读取历史思考、当前工具
续接仍成功。记录 APK 路径、大小、SHA-256、版本和安装结果。

最终汇报已有实现、实际补齐点、每条模型调用路径的审计结论、测试数量、全量失败
分类、APK 信息、未完成项和残余风险。在验收完成前不要声称完成；完成后仍等待
用户决定是否 commit 或 push。
