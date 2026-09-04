# 交给 Kelivo 修复窗口的 Prompt：世界书时间条件发布阻塞问题

请直接在本地 Kelivo 仓库中修复角色卡内嵌 SillyTavern 世界书的
`sticky/cooldown/delay` 组合条件漏检问题，完成测试、发布候选检查，并重新构建
Android Release APK。不要只给出方案，要实施、验证并提供完整结果。

## 开始前必须阅读

1. `E:\杂项\chatbox\kelivo\AGENTS.md`
2. `E:\杂项\chatbox\kelivo\docs\sillytavern-character-card-roleplay-implementation-plan.md`
3. `E:\杂项\chatbox\kelivo\docs\sillytavern-character-card-roleplay-fix-plan.md`
4. `E:\杂项\chatbox\kelivo\docs\sillytavern-world-book-timing-condition-fix-plan.md`

最后一份文档是本轮任务的权威验收规格。本轮不要重做已经通过验证的角色卡、
RP、导入回滚、PNG 解析、长文本防抖或历史推理过滤主体。

## 工作树保护

仓库路径：

```text
E:\杂项\chatbox\kelivo
```

当前分支预期为 `codex/sillytavern-prompt-presets`，其中包含大量尚未提交的用户
工作。开始时先执行并汇报：

```powershell
git status --short --branch
git diff --stat
git log -3 --oneline --decorate
```

严禁执行 `git reset --hard`、`git checkout --`、`git clean`、stash 或切换分支。
不得覆盖、丢弃或回退已有未提交改动。除非用户在该窗口另行明确要求，完成后
不得 commit、push、创建标签、修改远端或创建 GitHub Release。

## 已确认的问题

文件：

```text
lib/features/world_book/services/world_book_import_service.dart
```

`_hasUnsupportedCharacterCardEntrySettings` 当前将三个独立字段写成一条空值合并链：

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

因此下面的真实 SillyTavern 形状会只读取 `sticky: 0`，忽略
`cooldown: 5`：

```json
{
  "sticky": 0,
  "cooldown": 5,
  "delay": 0
}
```

这会让 Kelivo 无法准确表达的高级时间条件被静默放宽，使条目错误保持启用。

## 必须采用测试先行

先在
`test/features/world_book/character_card_world_book_import_test.dart` 中增加回归测试，
必要时扩展现有 fixture。测试至少覆盖：

1. 顶层 `sticky: 0, cooldown: 0, delay: 0` 保持启用；
2. 顶层 `sticky > 0` 时禁用；
3. 顶层 `sticky: 0, cooldown > 0, delay: 0` 时禁用；
4. 顶层 `sticky: 0, cooldown: 0, delay > 0` 时禁用；
5. 三个字段均缺失时保持启用；
6. `extensions` 中三个字段均为 0 时保持启用；
7. `extensions.sticky: 0, extensions.cooldown > 0` 时禁用；
8. `extensions.sticky: 0, extensions.delay > 0` 时禁用。

每个非默认条件用例还要验证：

- 条目被保留但 `enabled == false`，不是被跳过；
- `hasUnsupportedSettings == true`；
- 导入报告包含现有的不支持条件警告；
- 可支持的关键词、内容、顺序和注入字段没有丢失。

先只添加测试并运行它，记录修复前失败，确认测试能捕获
`sticky: 0 + cooldown > 0` 的漏洞。然后再修改生产代码。

## 最小修复要求

分别判断三个语义，保持每个字段的“entry 顶层优先、`extensions` 回退”规则：

```dart
_meaningful(entry['sticky'] ?? extensions['sticky']) ||
_meaningful(entry['cooldown'] ?? extensions['cooldown']) ||
_meaningful(entry['delay'] ?? extensions['delay'])
```

默认值 `0`、`false` 和缺失不得禁用普通条目；任意非默认有效值必须让角色卡
内嵌世界书条目默认禁用。

不要：

- 实现或近似模拟 SillyTavern 的 sticky/cooldown/delay 运行时；
- 修改全局 `_meaningful`；
- 改变独立世界书导入策略；
- 放宽正则、脚本、JavaScript、插件或未知 extension 的安全边界；
- 顺带重构世界书服务、Provider 或角色卡导入架构；
- 为通过测试而删断言、忽略异常或扩大 analyzer 排除范围。

## 必须执行的聚焦测试

修复后至少运行：

```powershell
flutter test test/features/world_book/character_card_world_book_import_test.dart
flutter test test/features/world_book/services/world_book_import_service_test.dart
flutter test test/features/character_card
flutter test test/features/home/services/message_builder_roleplay_test.dart
flutter test test/features/home/services/message_builder_thinking_filter_test.dart
flutter test test/core/providers/prompt_preset_provider_test.dart
flutter test test/features/home/services/message_builder_prompt_preset_test.dart
```

还要确认现有真实 SillyTavern 默认字段 fixture、角色卡导入回滚、大 IDAT PNG、
RP 开场白、临时对话双向切换和提供商协议制品过滤测试没有回归。

## 静态检查和全量测试

只格式化本轮实际修改的 Dart 文件。然后执行：

```powershell
dart analyze --fatal-infos lib test
git diff --check
flutter test
```

当前全量基线：

```text
修复前：4043 passed, 26 failed, 6 skipped
当前复核：4045 passed, 25 failed, 6 skipped
```

已知失败为 Windows 文件锁、临时目录清理、测试环境缺少 `path_provider`、资源
释放和下载清理问题。请保存最终全量日志，逐项与基线比较。任何新增世界书、
角色卡、RP、消息构建或提供商测试失败都必须修复，不能归到环境基线。

Flutter 测试工具在这台机器上可能自动修改 `analysis_options.yaml`，加入
`build/android/ios/web/windows/macos/linux` 排除项。全部 Flutter 命令完成后检查
该文件；如发生自动改写，只用精确补丁删除本次自动生成的片段，不要覆盖文件，
也不要把它提交。

## Android Release APK

全部代码验证通过后：

1. 将已验证源码同步到 `E:\devtools\kelivo-apk-build`；
2. 不复制或提交 `android/key.properties`、密钥、SDK 路径、`.dart_tool` 或 `build`；
3. 比较源仓库与构建目录的 `lib`、`assets`、`pubspec.yaml`、`pubspec.lock` 和 Android
   核心配置，必须内容一致；
4. 使用 JDK 17 执行 `flutter build apk --release`；
5. 使用 `adb install -r` 安装到可用模拟器或设备并冷启动；
6. 手动导入 `sticky: 0, cooldown > 0` 的最小角色卡，确认条目被保留、默认禁用并
   出现警告；
7. 手动导入三个字段均为 0 的角色卡，确认普通关键词条目保持启用；
8. 记录 APK 绝对路径、大小、SHA-256、版本名、versionCode、安装和启动结果。

以下旧 APK 包含漏洞，必须标记为过期，不能作为最终交付物：

```text
E:\devtools\kelivo-apk-build\build\app\outputs\flutter-apk\app-release.apk
SHA-256: 168EFB6BACA076184A9A872FE66234A621B2A5CFA81806BEB5AC1336687E79C3
```

若只是准备功能分支推送，不要自行修改版本号。若用户要求创建 GitHub Release，
先报告当前 `v1.2.5` 标签和 `1.2.5+72` 版本冲突风险，等待用户确认新的 fork 标签
和高于 `72` 的 versionCode。

## 最终汇报格式

完成后必须汇报：

1. 修复前失败测试及其断言；
2. 生产代码的最小修改和为什么能覆盖三个独立条件；
3. 顶层与 `extensions` 的八组时间条件测试结果；
4. 独立世界书、角色卡、RP、推理过滤和提示词预设回归结果；
5. analyzer、`git diff --check` 和全量测试的真实结果与失败分类；
6. `analysis_options.yaml` 和无关 diff 的最终状态；
7. 新 APK 的路径、大小、SHA-256、版本、安装和冷启动结果；
8. 构建目录与已测试源码的一致性结果；
9. 未完成项和残余风险；
10. 最终 `git status --short --branch`。

在全部验收完成前不要声称可以发布；完成后也不要自行 commit 或 push，等待用户
审查和授权。
