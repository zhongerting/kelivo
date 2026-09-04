# 交给 Kelivo 修复窗口的 Prompt

请在本地 Kelivo 仓库中修复当前未提交的“SillyTavern 角色卡导入、RP 助手和
历史推理过滤”实现，完成回归测试并重新交付 Android Release APK。

开始前必须完整阅读：

1. `E:\杂项\chatbox\kelivo\AGENTS.md`
2. `E:\杂项\chatbox\kelivo\docs\sillytavern-character-card-roleplay-implementation-plan.md`
3. `E:\杂项\chatbox\kelivo\docs\sillytavern-character-card-roleplay-fix-plan.md`
4. `E:\杂项\chatbox\kelivo\docs\sillytavern-prompt-preset-implementation-plan.md`

本修复计划是当前任务的权威验收规格。不要重做已经正确实现的角色卡和推理
过滤主体，只在现有架构上修复审查发现的问题。

## 工作树保护

当前分支预期为 `codex/sillytavern-prompt-presets`，工作树中包含未提交的角色卡、
RP、历史推理过滤和文档改动。开始时先执行并汇报：

```powershell
git status --short --branch
git diff --stat
git log -3 --oneline --decorate
```

严禁执行 `git reset --hard`、`git checkout --`、`git clean`、stash 或切换分支。不得
覆盖用户的未提交改动。需要清理无关格式化时，使用精确补丁只恢复对应片段。

除非用户在该窗口另行明确要求，完成后不得 commit、push、创建 GitHub Release
或修改远端。

## 修复一：角色卡内嵌世界书误禁用

当前 `WorldBookImportPolicy.characterCard` 会因字段存在而不是实际语义禁用条目。
请修改为基于值的保守判断：

- 常见默认值不得造成普通关键词条目被禁用，包括 `selectiveLogic: 0`、
  `group: ""`、`group_weight: 100`、`role: 0`、`sticky/cooldown/delay: 0`、
  `vectorized: false`、空 `characterFilter` 和显示索引类字段。
- `useProbability: true` 且 `probability != 100` 时才因概率语义禁用；
  `useProbability: false` 不应被禁用。
- 没有 secondary key 时，默认 selective 标记不应单独造成禁用。
- `role: 0` 在 before/after-system 类位置不应造成禁用；仅在实际注入位置依赖
  Kelivo 无法表达的 role 时禁用。
- 依赖 secondary key、AND/NOT、启用概率、递归、非空 group、sticky、cooldown、
  delay、vector、whole-word、非空 character filter 或不支持位置的条目仍禁用。
- 未知 extension 只有在其值非空、非默认且可能影响语义时才禁用，但始终不导入
  或执行其内容。
- 纯正则关键词、角色卡正则脚本和插件安全边界保持不变。
- 不得改变世界书页面中的独立 SillyTavern 世界书导入策略。

新增一个包含真实 ST 默认字段形状的 fixture 和测试，不能只使用当前的极简条目。
测试必须同时证明普通条目保持启用，真正高级条件仍禁用，且导入报告统计正确。

## 修复二：RP 开场白与临时对话

当前 `_temporaryConversationHasOnlyOpeningMessage` 先要求对话已经是 temporary，导致
普通 RP 新对话插入开场白后无法切换为临时对话。

请拆分“是否只有开场白”和“是否临时对话”。保留已有防重入和每对话仅插入
一次的逻辑。新增 HomeViewModel/控制器层测试，至少覆盖：

1. 普通 RP 对话只有开场白时切换为临时对话；
2. 临时 RP 对话只有开场白时切回普通对话；
3. 切换后开场白仍只有一条；
4. 已有用户消息、模型回复或额外 preset message 时不允许切换。

## 修复三：导入回滚的强异常安全

必须保留回滚功能。一次导入跨越文件和多个 preferences/provider，不能依赖单一
数据库事务。

请：

- 记录导入前当前助手 ID。
- 使 `AssistantProvider.addAssistantObject` 在列表持久化或当前 ID 持久化失败时恢复
  调用前的内存和持久化状态。
- Coordinator catch 按本次 UUID 查询并清理，不只依赖在 await 返回后才设置的
  `assistantAdded`/`worldBookAdded` 布尔值。
- 失败时尽最大可能解绑和删除本次世界书、删除本次助手、恢复原当前助手并
  删除本次头像。
- 不删除导入前数据，不用空 catch 完全掩盖回滚失败。
- 通过 fake provider/preferences 或最小故障注入测试助手保存、当前 ID 保存、世界书保存
  和绑定失败的每一个阶段。

每个失败测试都要断言助手、世界书、绑定、原当前助手和头像均无半成品。

## 修复四：取消 PNG 每 chunk 2 MiB 限制

- 删除 `maxPngChunkBytes` 对所有 chunk 的统一拒绝。
- 保留 PNG 总大小限制，首先保持 32 MiB。只在真实样本超过时才调整为 64 MiB。
- 保留并校准角色元数据、Base64 解码后 JSON 和解压膨胀限制。
- 只对 `tEXt`/`iTXt` 创建 chunk 数据副本，跳过大 `IDAT` 时不要额外复制整块。
- 测试一个单 `IDAT` 超过 2 MiB 但总文件受控、且包含小型有效 `chara/ccv3`
  元数据的 PNG，它必须成功导入。
- 超大元数据、超总大小、截断 chunk、缺少 IEND 和解压膨胀仍必须失败。

## 修复五：RP 长文本编辑性能

人物设定和开场白不应每输入一个字符就序列化并持久化全部助手列表。

- 移除人物设定每字符触发的无意义 `setState`。
- 为人物设定和开场白增加有界防抖，在失焦或返回页面前 flush 最终内容。
- 不要在 `dispose` 中启动无法等待或观察的异步保存。
- 测试快速连续输入不会每字符持久化，用户立即返回时最后内容仍已保存。

不要顺带重构整个助手编辑页或扩大到无关设置项。

## 清理无关改动

使用精确补丁去掉：

- `analysis_options.yaml` 新增的全平台目录排除；
- `lib/core/database/chat_database_repository.dart` 的纯格式化改动；
- `test/core/providers/mcp_provider_remote_session_test.dart` 的纯格式化改动；
- `test/features/home/services/memory_tools_test.dart` 的纯格式化改动。

不得用 reset/checkout 覆盖整个文件。只格式化本次实际修改的 Dart 文件。

## 必须验证

先分阶段运行新增测试，然后至少运行：

```powershell
flutter test test/features/character_card
flutter test test/core/models/assistant_roleplay_test.dart
flutter test test/features/world_book/character_card_world_book_import_test.dart
flutter test test/features/world_book/services/world_book_import_service_test.dart
flutter test test/features/home/services/message_builder_roleplay_test.dart
flutter test test/features/home/services/message_builder_thinking_filter_test.dart
flutter test test/core/providers/prompt_preset_provider_test.dart
flutter test test/features/home/services/message_builder_prompt_preset_test.dart
```

重跑现有 Kimi、GLM、OpenAI reasoning details、OpenRouter tools、Claude history/tool blocks
和 Gemini function calling/thought signature 兼容测试。

最后执行：

```powershell
dart format <本次实际修改文件>
flutter gen-l10n
dart analyze --fatal-infos lib test
git diff --check
flutter test
```

`analysis_options.yaml` 清理后的严格分析必须通过。全量测试如仍有 Windows 环境基线失败，
列出每类错误、与修复前基线对比，不得把本功能失败归入环境问题。

## Android Release APK

所有修复和聚焦测试通过后：

1. 把已验证源码同步到 `E:\devtools\kelivo-apk-build`。
2. 确保不提交 `android/key.properties`、密钥、SDK 路径或构建目录。
3. 执行 `flutter build apk --release`。
4. 在可用模拟器/设备上执行 `adb install -r`。
5. 手动验收真实默认字段世界书、RP 临时对话双向切换、大 IDAT PNG、长文本编辑和
   Context Logger 历史推理过滤。
6. 校验构建目录核心文件与已测试工作树一致。

## 最终汇报格式

完成后汇报：

- 五类修复的具体行为和修改文件；
- 真实 SillyTavern 默认字段与高级条件的测试结果；
- 导入回滚的故障注入结果；
- RP 临时对话和开场白防重复结果；
- 大 IDAT PNG 与元数据安全限制结果；
- 长人物设定编辑性能与最终保存结果；
- 聚焦测试、提供商回归、analyzer 和全量测试的真实数量与失败分类；
- 无关 diff 清理结果和最终 `git status --short --branch`；
- APK 绝对路径、大小、SHA-256、版本号、安装和冷启动结果；
- 未完成项和剩余风险。

在所有验收完成前不要声称功能已完成，也不要提交或推送。
