# Kelivo 角色卡、RP 与推理过滤修复计划

## 1. 背景与目标

当前已完成 SillyTavern JSON/PNG 角色卡导入、RP 助手、内嵌世界书绑定和
历史推理过滤的主体实现。聚焦测试和提供商兼容测试已通过，但代码审查
发现了四个需要在正式提交前修复的行为问题，以及一组不应进入本功能提交的
无关改动。

本计划的目标是：

1. 使真实 SillyTavern 角色卡内嵌世界书的默认字段不再造成误禁用；
2. 恢复 RP 开场白对话与临时对话的正常双向切换；
3. 使角色卡导入失败时能可靠清理助手、头像、世界书和绑定半成品；
4. 取消 PNG 每个 chunk 2 MiB 的不合理限制，同时保留必要的总大小和元数据
   防护；
5. 清理无关格式化和 analyzer 配置改动；
6. 重新完成聚焦测试、提供商回归、静态分析、Android 手动验收和 Release APK
   构建。

本次不扩展成完整 SillyTavern 实现，不导入或执行角色卡正则脚本、JavaScript、
Tavern Helper、JS-Slash-Runner 或其他插件内容。

## 2. 当前已确认状态

- 工作分支：`codex/sillytavern-prompt-presets`。
- 提示词预设已在 HEAD 中；角色卡、RP 和推理过滤仍是未提交改动。
- 新增及关联聚焦测试已有 35 项通过。
- Kimi、GLM、OpenAI reasoning details、Claude 工具历史和 Gemini thought signature
  等提供商测试已有 64 项通过。
- `dart analyze --fatal-infos lib test` 已通过。
- 已构建 APK 的核心功能源文件与当前仓库一致，但该 APK 仍包含本计划要修复的
  问题，不作为最终版。

## 3. 修复原则

1. 不执行 `reset --hard`、`checkout --`、`clean`、`stash` 或切换分支。
2. 保留当前已实现的提示词预设、角色卡、快捷回复、指令注入和上游同步功能。
3. 只修复角色卡内嵌世界书的 `characterCard` 安全策略，不改变世界书页面的
   独立 SillyTavern 世界书导入行为。
4. 安全判断必须基于“字段的实际语义”，不能仅因字段存在就禁用条目。
5. 不得为通过测试而忽略异常、删除断言、降低 analyzer 规则或放宽脚本安全边界。

## 4. 阶段一：基线保护

### 实施

1. 完整阅读 `AGENTS.md`、原实施计划和本修复计划。
2. 记录 `git status --short --branch`、`git diff --stat` 和 `git log -3 --oneline`。
3. 在修改前重跑现有角色卡、世界书、RP、推理过滤和提示词预设聚焦测试。
4. 不重新格式化整个仓库。

### 完成标准

- 已有未提交工作未丢失。
- 修复前的已知失败和当前工作树均有记录。

## 5. 阶段二：修复角色卡内嵌世界书判断

### 5.1 问题

当前逻辑会在 `extensions` 出现白名单外键时直接禁用条目，并将下列常见默认值
也当成不支持条件：

```text
display_index
probability: 100
useProbability: true
selectiveLogic: 0
group: ""
group_weight: 100
role: 0
sticky: 0
cooldown: 0
delay: 0
vectorized: false
characterFilter: empty
```

这些字段在值为默认或空时通常不改变条目的触发语义。

### 5.2 实施

1. 将“是否出现未知键”改为“是否存在非默认且 Kelivo 无法表达的语义”。
2. 对布尔值 `false`、数字 `0`、空字符串、空数组、空对象和已知默认数值分别处理。
3. `useProbability == true && probability != 100` 时禁用；`useProbability == false`
   表示不使用概率，不应因此禁用。
4. 只有存在非空 secondary key 或确实需要 AND/NOT 逻辑时，才因 selective 语义禁用。
5. `role: 0` 在 before/after-system 类位置不改变 Kelivo 的合并行为，不应
   禁用条目。对 at-depth 等确实依赖不可表达 role 的情况仍应禁用并警告。
6. 未知 extension 如果携带非空、非默认内容，仍按不可确定语义禁用；不执行、
   不转换、不扩大触发范围。
7. 修正导入报告，只有条目实际被禁用或调整时才报告对应警告。

### 5.3 测试

新增一个接近真实 SillyTavern 导出的角色卡内嵌世界书 fixture，至少覆盖：

- 携带全部常见默认字段的普通关键词条目保持启用；
- `useProbability: false` 与 `probability < 100` 的语义区别；
- 启用概率、secondary key、AND/NOT、group、sticky、cooldown、delay、vector、
  whole-word 等高级条件仍默认禁用；
- 空 `characterFilter` 安全，非空过滤器禁用；
- 纯正则关键词禁用，混合关键词仅保留普通关键词；
- 独立世界书导入的现有测试结果不变。

### 5.4 完成标准

- 真实默认导出形状中的普通条目可以启用并触发。
- 确实依赖不支持高级条件的条目仍不会被静默放宽。

## 6. 阶段三：修复 RP 开场白对话与临时对话切换

### 实施

1. 将“对话是否只有 RP 开场白”与“对话是否临时”拆分为两个独立判断。
2. 判断“只有开场白”时不先要求 conversation 已经是 temporary。
3. 保留普通对话和临时对话中开场白只插入一次的保证。
4. 有用户消息、模型回复或额外 preset messages 时，仍不允许将已有内容的对话直接
   切换为临时对话。

### 测试

- 空的普通助手对话可切换临时状态；
- 普通 RP 对话只有一条开场白时可切换为临时对话；
- 临时 RP 对话只有一条开场白时可切回普通新对话；
- 切换后只有一条开场白，重建、重开和重试不重复插入；
- 对话已有用户消息或额外预置消息时不允许切换。

### 完成标准

- 移动端和桌面端的临时对话按钮在上述状态下显示和行为正确。

## 7. 阶段四：加固导入回滚

### 7.1 需要保留回滚的原因

一次导入会跨越头像文件、助手偏好、世界书偏好、助手与世界书绑定和
当前助手选择，无法用一个数据库事务覆盖。所以失败时仍需要补偿清理。

### 7.2 实施

1. 在导入开始时记录原当前助手 ID。
2. 使 `AssistantProvider.addAssistantObject` 具备强异常安全：任何持久化步骤失败时，
   内存列表、当前 ID 和已持久化数据都应恢复为调用前状态。
3. Coordinator 在 catch 中不只依赖 `assistantAdded`/`worldBookAdded` 布尔值，而是按
   本次生成的 UUID 查询并尝试清理。
4. 清理顺序要保证不遗留绑定：解绑本次世界书、删除本次世界书、删除本次助手、
   恢复原当前助手、删除本次头像。
5. 回滚不得删除导入前已存在的助手、世界书、头像或绑定。
6. 保留原始失败原因，同时在诊断中记录回滚失败，不用空 catch 完全吞掉。

### 7.3 测试

通过可控失败的 fake provider/preferences 或最小故障注入，至少覆盖：

- 助手列表持久化失败；
- 当前助手 ID 保存失败；
- 世界书保存失败；
- 世界书绑定失败；
- 导入成功时不触发误清理；
- 每个失败场景后，助手、世界书、绑定、当前助手和头像均与导入前一致。

### 7.4 完成标准

- 不会因为某一步部分成功而留下可见半成品。
- 正常导入、助手复制、删除和备份恢复行为不变。

## 8. 阶段五：修复 PNG chunk 限制

### 实施

1. 删除对所有 PNG chunk 统一应用的 2 MiB 限制。
2. 保留 PNG 文件总大小限制，首先保持 32 MiB；如用户真实样本超过该大小，
   再基于样本调整到 64 MiB，不完全取消总限制。
3. 先读取 chunk 头和 type，只对 `tEXt`/`iTXt` 元数据创建必要的数据副本；
   跳过 `IDAT` 时不再额外 `sublist` 复制整个图像块。
4. 保留 chunk 数量、长度边界、IEND、Base64、UTF-8、解码后 JSON 大小和压缩膨胀检查。
5. 元数据限制应区分“编码后 PNG 文本”和“Base64 解码后 JSON”，两者的限制应互相
   一致，不应出现允许 8 MiB JSON 却无法容纳其 Base64 文本的矛盾。

### 测试

- 单个 `IDAT` 大于 2 MiB、角色元数据较小的合法测试 PNG 可导入；
- 大 `IDAT` 不会被计入角色元数据限制；
- 超大 `ccv3/chara` 元数据仍被拒绝；
- 超过 PNG 总大小、截断 chunk、缺失 IEND 和解压膨胀输入仍被拒绝。

### 完成标准

- 高分辨率但文件总大小受控的角色卡 PNG 可正常导入。
- 恶意元数据和压缩炸弹防护仍然存在。

## 9. 阶段六：降低 RP 大文本编辑写入压力

角色人物设定可能很长。当前编辑框每输入一个字符就序列化并写入全部助手
配置，人物设定还会触发整页重建。

### 实施与测试

1. 移除人物设定输入时没有 UI 需求的每字符 `setState`。
2. 对人物设定和开场白使用有界防抖写入，并在失焦、返回页面和销毁前刷新待写内容。
3. 不得因用户输入后立即返回而丢失最后一段文本。
4. 增加组件或 provider 测试，验证快速连续输入不会每字符持久化，离开页面前会
   保存最终文本。

如现有页面架构无法安全地在 dispose 中等待异步写入，应在路由返回前显式 flush，
而不是在 dispose 中启动一个无法观察结果的异步任务。

## 10. 阶段七：清理提交边界

### 实施

1. 从本次改动中去掉 `analysis_options.yaml` 新增的 `build/android/ios/web/windows/macos/linux`
   排除项，恢复功能开发前的 analyzer 范围。
2. 去掉下列与本功能无关的纯格式化改动：
   - `lib/core/database/chat_database_repository.dart`
   - `test/core/providers/mcp_provider_remote_session_test.dart`
   - `test/features/home/services/memory_tools_test.dart`
3. 只用精确补丁恢复这些文件的无关片段，不覆盖其他未提交工作。
4. 只格式化本次实际修改的 Dart 文件，避免再次引入全仓格式化噪声。
5. 运行 `git diff --check` 并检查最终 `git diff --stat`。

### 完成标准

- 工作树仅包含提示词预设后续必要文档、角色卡、RP、推理过滤、本次修复和
  相关测试。

## 11. 阶段八：回归验证

### 11.1 必须通过的聚焦测试

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

还必须运行新增的：

- 真实 SillyTavern 默认世界书字段测试；
- RP 开场白与临时对话双向切换测试；
- 导入各个持久化阶段的故障注入和回滚测试；
- 单个大于 2 MiB IDAT 的 PNG 角色卡测试；
- RP 大文本编辑防抖与最终刷新测试。

### 11.2 提供商回归

重跑现有的 Kimi、GLM、OpenAI reasoning details、OpenRouter tools、Claude history/tool
blocks 和 Gemini function calling/thought signature 测试。当前工具续接所需的推理和签名
不得被历史过滤误删。

### 11.3 格式化和静态分析

```powershell
dart format <本次实际修改的 Dart 文件>
flutter gen-l10n
dart analyze --fatal-infos lib test
git diff --check
```

`dart analyze` 必须在恢复 `analysis_options.yaml` 后仍为 `No issues found`。

### 11.4 全量测试

```powershell
flutter test
```

如 Windows 仍出现已知文件锁、`path_provider` 测试插件或路径分隔符问题，必须：

1. 列出失败测试和错误类型；
2. 与修复前基线比较；
3. 证明新增和受影响聚焦测试全部通过；
4. 不用修改 analyzer 或业务代码的方式遮掩环境失败。

## 12. 阶段九：Android 手动验收和 Release APK

1. 将已验证源码同步到 ASCII 构建目录 `E:\devtools\kelivo-apk-build`。
2. 确认密钥、`key.properties`、本地 SDK 配置和构建产物不进入 Git。
3. 构建 `flutter build apk --release`。
4. 使用 `adb install -r` 安装到可用模拟器或设备。
5. 手动验证：
   - 导入带常见默认字段的 JSON/PNG 角色卡；
   - 普通世界书条目保持启用、自动绑定并能触发；
   - 高级条件、正则脚本和插件内容仍禁用或忽略；
   - 普通 RP 新对话与临时 RP 对话可双向切换；
   - 开场白不重复；
   - 大 IDAT PNG 角色卡可导入且头像可显示；
   - 长人物设定编辑时键盘响应正常，离开页面后文本已保存；
   - Context Logger 仍证明历史推理不进入后续上下文。
6. 记录 APK 绝对路径、大小、SHA-256、版本号和安装/冷启动结果。
7. 比较构建目录与源工作树的核心文件哈希，确保 APK 对应的就是已测试源码。

## 13. 最终验收清单

- [ ] 独立 SillyTavern 世界书导入行为未改变。
- [ ] 角色卡内嵌世界书中的常见默认字段不再误禁用条目。
- [ ] 高级条件、纯正则关键词、脚本和插件内容仍安全禁用或忽略。
- [ ] 普通 RP 开场白对话和临时 RP 开场白对话可双向切换。
- [ ] 开场白在每个 conversation 中只插入一次。
- [ ] 导入任意持久化阶段失败后不留下助手、头像、世界书或绑定半成品。
- [ ] 单个大于 2 MiB 的 IDAT chunk 不会造成合法角色卡被拒绝。
- [ ] 总文件、元数据、解码后 JSON 和解压膨胀保护仍有效。
- [ ] 长人物设定编辑不再每字符写入存储，最终文本不丢失。
- [ ] 历史推理过滤和提供商工具续接测试仍通过。
- [ ] `analysis_options.yaml` 没有与功能无关的扩大排除。
- [ ] 最终 diff 不包含无关全仓格式化改动。
- [ ] 聚焦测试、提供商回归和严格静态分析全部通过。
- [ ] 新 Release APK 由已测试源码构建，可安装、冷启动和完成手动验收。

## 14. Git 交付边界

本计划执行完成后先汇报最终 diff、测试、APK 和剩余风险。除非用户在执行
窗口中明确要求，不执行 commit、push、创建 GitHub Release 或改动远端分支。
