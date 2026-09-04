# Kelivo 角色卡世界书时间条件发布阻塞修复计划

## 1. 背景

SillyTavern 角色卡、RP 助手、内嵌世界书和历史推理过滤的主体实现已经完成，
主要回归测试、严格静态分析、Android 安装与手动验收均已通过。发布前审查发现
一个仍需修复的世界书转换漏洞：

```dart
_meaningful(
  entry['sticky'] ??
      entry['cooldown'] ??
      entry['delay'] ??
      extensions['sticky'] ??
      extensions['cooldown'] ??
      extensions['delay'],
)
```

`sticky`、`cooldown` 和 `delay` 是三个相互独立的条件，不能用一条 `??` 链选择
其中一个。真实 SillyTavern 导出通常会同时写出这些字段。例如：

```json
{
  "sticky": 0,
  "cooldown": 5,
  "delay": 0
}
```

当前代码只会读取第一个非 `null` 的 `sticky: 0`，从而忽略有效的
`cooldown: 5`，错误地让该条目保持启用。Kelivo 无法准确表达这些高级时间条件，
因此正确行为应是将该条目导入但默认禁用，并在导入报告中给出不支持条件警告。

## 2. 目标与边界

本次只完成以下工作：

1. 分别检查 `sticky`、`cooldown` 和 `delay`；
2. 同时覆盖字段位于 entry 顶层和 `extensions` 中的 SillyTavern 形状；
3. 默认值 `0`、`false` 或缺失时不误禁用普通关键词条目；
4. 任一时间条件为非默认有效值时，将角色卡内嵌世界书条目默认禁用；
5. 保持独立世界书导入、正则安全边界、角色卡解析、RP 和推理过滤行为不变；
6. 修复后重新验证并构建新的 Android Release APK。

本次不得顺带实现 SillyTavern 的 sticky、cooldown 或 delay 运行时语义，也不得把
它们近似转换成 Kelivo 的其他字段。当前产品策略仍是“无法准确表达则安全禁用”。

## 3. 工作树保护

当前分支预期为 `codex/sillytavern-prompt-presets`，工作树中已有大量尚未提交的
角色卡、RP、推理过滤、测试和文档改动。

实施时必须：

1. 先记录 `git status --short --branch`、`git diff --stat` 和
   `git log -3 --oneline --decorate`；
2. 不执行 `git reset --hard`、`git checkout --`、`git clean`、stash 或切换分支；
3. 不覆盖或回退现有未提交改动；
4. 只修改本问题需要的世界书判断、测试 fixture/测试文件和必要文档；
5. 不修改 analyzer 规则来规避检查；
6. 未经用户明确要求，不执行 commit、push、创建标签或 GitHub Release。

## 4. 第一阶段：用回归测试复现漏洞

优先在
`test/features/world_book/character_card_world_book_import_test.dart` 中增加精确测试，
必要时扩展现有真实字段 fixture。

至少覆盖以下输入和预期：

| 输入 | 预期 |
| --- | --- |
| `sticky: 0, cooldown: 0, delay: 0` | 普通关键词条目保持启用 |
| `sticky: 2, cooldown: 0, delay: 0` | 条目默认禁用 |
| `sticky: 0, cooldown: 5, delay: 0` | 条目默认禁用 |
| `sticky: 0, cooldown: 0, delay: 1` | 条目默认禁用 |
| 三个字段均缺失 | 普通关键词条目保持启用 |
| `extensions` 中三个字段均为 0 | 普通关键词条目保持启用 |
| `extensions.sticky: 0, extensions.cooldown: 5` | 条目默认禁用 |
| `extensions.sticky: 0, extensions.delay: 1` | 条目默认禁用 |

测试还应断言：

- 非默认时间条件使 `hasUnsupportedSettings` 为 `true`；
- 导入警告包含现有的不支持世界书条件提示；
- 条目仍被持久化，只是 `enabled == false`，不会被静默跳过；
- 普通关键词、内容、顺序和角色等可支持字段不丢失；
- 独立世界书导入测试结果不变。

先只添加测试并运行，确认至少 `sticky: 0 + cooldown > 0` 的用例在当前实现上失败。
这一步用于证明测试确实捕获了漏洞，而不是只验证修复后的代码。

## 5. 第二阶段：最小修复

修改
`lib/features/world_book/services/world_book_import_service.dart` 中
`_hasUnsupportedCharacterCardEntrySettings` 的时间条件判断。

推荐保持现有 entry 优先、`extensions` 回退的字段来源规则，但对三个语义分别判断：

```dart
_meaningful(entry['sticky'] ?? extensions['sticky']) ||
_meaningful(entry['cooldown'] ?? extensions['cooldown']) ||
_meaningful(entry['delay'] ?? extensions['delay'])
```

也可以提取一个很小的私有辅助函数，但只有在能让逻辑和测试更清楚时才这样做。
不要修改全局 `_meaningful` 的行为，因为它还服务于其他字段和独立世界书导入路径，
扩大修改会增加不必要的回归面。

修复完成后，先重跑刚增加的测试，确认由失败变为通过。

## 6. 第三阶段：聚焦回归

至少运行：

```powershell
flutter test test/features/world_book/character_card_world_book_import_test.dart
flutter test test/features/world_book/services/world_book_import_service_test.dart
flutter test test/features/character_card
flutter test test/features/home/services/message_builder_roleplay_test.dart
flutter test test/features/home/services/message_builder_thinking_filter_test.dart
flutter test test/core/providers/prompt_preset_provider_test.dart
flutter test test/features/home/services/message_builder_prompt_preset_test.dart
```

验收要求：

- 新增的时间条件组合全部通过；
- 现有真实 SillyTavern 默认字段 fixture 仍保持 `3` 条启用、`12` 条禁用、
  `0` 条跳过，除非新增测试条目后明确同步调整统计；
- 角色卡导入回滚、大 IDAT PNG、RP 开场白和历史推理过滤测试不回归；
- 独立世界书导入策略没有行为变化。

## 7. 第四阶段：静态检查与全量基线

只格式化本次实际修改的 Dart 文件，然后执行：

```powershell
dart analyze --fatal-infos lib test
git diff --check
flutter test
```

当前机器上的 Flutter 工具可能自动向 `analysis_options.yaml` 写入
`build/android/ios/web/windows/macos/linux` 排除项。若再次发生，必须在全部 Flutter
命令结束后用精确补丁删除这次自动生成的片段，不能将其带入提交。

全量测试基线为：

```text
修复前：4043 passed, 26 failed, 6 skipped
当前复核：4045 passed, 25 failed, 6 skipped
```

已知失败集中于 Windows 文件锁、临时目录清理、测试环境缺少 `path_provider`
实现、资源释放和下载文件清理。最终结果必须逐项与基线比较；任何新增世界书、
角色卡、RP、消息构建或提供商测试失败均为发布阻塞，不能归为环境问题。

## 8. 第五阶段：APK 与发布候选验证

旧 APK：

```text
E:\devtools\kelivo-apk-build\build\app\outputs\flutter-apk\app-release.apk
SHA-256: 168EFB6BACA076184A9A872FE66234A621B2A5CFA81806BEB5AC1336687E79C3
```

旧 APK 包含本次要修复的逻辑，修复后必须视为已过期，不能继续作为最终 Release
附件。

新构建流程：

1. 将已测试源码精确同步到 ASCII 路径 `E:\devtools\kelivo-apk-build`；
2. 不同步或提交 `android/key.properties`、密钥、SDK 路径、`.dart_tool` 和 `build`；
3. 比较两个目录的 `lib`、`assets`、`pubspec.yaml`、`pubspec.lock` 和 Android 核心
   配置，确认运行时代码一致；
4. 使用 JDK 17 执行 `flutter build apk --release`；
5. 使用 `adb install -r` 安装到可用模拟器或设备并冷启动；
6. 手动导入包含 `sticky: 0, cooldown > 0` 的最小角色卡，确认条目已导入、默认
   禁用且报告有警告；
7. 再导入三个字段均为 0 的普通角色卡，确认条目保持启用；
8. 记录新 APK 的绝对路径、大小、SHA-256、版本名、versionCode、安装和冷启动结果。

若只是提交并推送功能分支，不强制修改版本号。若要创建新的 GitHub Release，
必须使用区别于现有 `v1.2.5` 的 fork 标签，并确保 Android versionCode 高于当前
`72`；具体版本名和标签由用户确认后再修改或构建。

## 9. 最终发布门槛

- [ ] 已有失败测试能够在修复前复现漏洞；
- [ ] 三个时间字段在顶层和 `extensions` 中均被独立判断；
- [ ] 全部为默认值时普通条目不被误禁用；
- [ ] 任一非默认时间条件存在时条目被保守禁用；
- [ ] 导入统计和警告正确；
- [ ] 独立世界书导入行为不变；
- [ ] 角色卡、RP、推理过滤和提示词预设聚焦测试通过；
- [ ] `dart analyze --fatal-infos lib test` 为 `No issues found`；
- [ ] `git diff --check` 无 whitespace 错误；
- [ ] 全量测试没有新增的功能相关失败；
- [ ] `analysis_options.yaml` 和其他无关文件没有测试工具产生的改动；
- [ ] 新 APK 来自已测试源码，并完成安装、冷启动和两个时间条件样本的手动验收；
- [ ] 最终汇报列明未完成项和残余风险；
- [ ] 用户确认后才执行 commit、push 或创建 Release。
