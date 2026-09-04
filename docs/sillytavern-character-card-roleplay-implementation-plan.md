# Kelivo 精简角色卡与历史推理过滤实施计划

## 1. 目标

在已经完成 SillyTavern 提示词预设导入的 Kelivo 基础上，增加精简、可控的
RP 助手能力：

1. 支持从 SillyTavern PNG/JSON 角色卡创建 RP 助手；
2. 只导入人物设定、开场白、名称、头像和角色卡内嵌世界书；
3. 不导入或执行角色卡正则脚本、插件脚本和其他高级角色卡功能；
4. RP 助手在本地完整保存并按 Kelivo 原有界面显示推理过程；
5. 在以后每次组装模型上下文时，从已完成的历史回复中删除推理正文，只发送
   最终回答；
6. 不破坏同一轮工具调用续接所需的推理签名和提供商协议数据；
7. 最终交付可在 Android 真机安装的 Release APK。

本阶段不是 SillyTavern 完整复刻。角色卡只是创建 RP 助手的数据来源，Kelivo
不提供 JavaScript、HTML、插件或任意脚本运行环境。

## 2. 已确认的产品决策

1. 助手分为普通助手和 RP 助手，普通助手保持当前行为。
2. RP 助手在现有系统提示词之外增加“人物设定”和“开场白”。
3. “开场白”对应角色卡的 `first_mes`。
4. 人物设定由角色卡的 `description`、`personality` 和 `scenario` 组成。
5. 开场白只在创建新对话时作为第一条 `assistant` 消息插入一次，不在每轮作为
   系统提示词重复发送。
6. 角色卡的 `data.character_book` 转换成 Kelivo 世界书，并自动绑定到新建的
   RP 助手。
7. 角色卡导入后直接创建 RP 助手；首版不建立可复用的独立角色卡库。
8. RP 助手可以继续选择当前已经实现的一个提示词预设。
9. 角色卡不得覆盖 Kelivo 助手原有的系统提示词。
10. RP 助手默认开启“从未来上下文中排除历史推理”，普通助手默认关闭，避免
    改变已有助手行为。
11. 推理过滤不改变数据库内容、导出原文或聊天界面，只改变发送给模型的临时
    API 消息副本。
12. 不在聊天主界面增加角色卡或推理过滤快捷入口。

此前提示词预设计划中“思考标签按普通文本进入后续历史”的说明，只描述了
预设导入阶段当时的范围。本计划新增的 RP 助手上下文过滤是后续明确需求；它
不意味着执行预设或角色卡携带的正则。

## 3. 明确范围

### 3.1 导入并使用

角色卡中只使用以下字段：

| 角色卡字段 | Kelivo 目标 | 说明 |
| --- | --- | --- |
| `name` / `data.name` | 助手名称 | 缺失时使用文件名 |
| PNG 图像 | 助手头像 | 复制到应用管理的头像目录 |
| `description` | 人物设定的一部分 | 保留原文 |
| `personality` | 人物设定的一部分 | 保留原文 |
| `scenario` | 人物设定的一部分 | 保留原文 |
| `first_mes` | 开场白 | 新对话中插入一次 |
| `character_book` | Kelivo 世界书 | 采用安全降级规则转换 |
| `spec` / `spec_version` | 导入报告元数据 | 不参与提示词 |

V1 字段从根对象读取；V2/V3 优先从 `data` 读取。人物设定在 UI 中作为一个
可编辑字段保存，但合并时保留三个来源的边界，建议使用稳定标记：

```text
<character_description>
...
</character_description>

<character_personality>
...
</character_personality>

<character_scenario>
...
</character_scenario>
```

空字段不生成空标记。运行时对人物设定和开场白应用现有、安全的
`{{char}}`、`{{user}}` 占位符替换，不执行其他宏代码。

### 3.2 不导入或不启用

以下字段不进入 RP 助手提示词，也不得执行：

- `data.system_prompt`；
- `data.post_history_instructions`；
- `mes_example`；
- `alternate_greetings`；
- `extensions.depth_prompt`；
- `extensions.regex_scripts`；
- JavaScript、HTML、iframe、slash command 和插件配置；
- CharX/BYAF 资源与脚本；
- 未识别的 `extensions`；
- 角色卡携带的采样参数和模型参数。

导入报告必须列出存在但被忽略的内容类别和数量，不能只显示“导入成功”。
不保存可执行脚本文本是首选；如为诊断而保留来源元数据，也不得进入任何运行
路径、备份可执行配置或模型上下文。

## 4. 现有基础与复用原则

当前仓库已经具备：

- `Assistant`、`AssistantProvider` 及助手头像持久化；
- 每助手选择一个提示词预设的 Provider 和消息注入；
- SillyTavern 世界书 JSON/`character_book` 结构识别；
- 每助手启用世界书的映射；
- `ChatMessage` 的推理文本、推理分段和提供商制品；
- `ThinkingTagParser` 对旧式内联思考标签的解析；
- `MessageBuilderService` 的统一 API 消息构建；
- OpenAI 兼容、Claude、Gemini 的工具调用和推理续接逻辑。

实现时必须复用这些入口。不要创建第二套对话存储、世界书运行时、头像目录或
正则执行器。

## 5. 数据模型

建议扩展 `Assistant`：

```text
mode                         normal / roleplay
characterPrompt              人物设定，普通助手为空
firstMessage                 开场白模板，普通助手为空
excludeThinkingFromContext   是否从未来上下文排除历史推理
```

要求：

- 旧 JSON 中缺少字段时回退为 `normal`、空字符串、`false`；
- 从角色卡创建的助手使用 `roleplay`，过滤开关默认为 `true`；
- 普通助手也可以在高级设置中手动开启过滤，但默认行为不变；
- `copyWith`、序列化、复制助手、备份恢复和设置合并全部覆盖新字段；
- 删除/复制 RP 助手时正确处理头像和世界书绑定关系；
- 不把 `characterPrompt` 拼进 `systemPrompt` 持久化，二者始终可独立编辑。

首版不增加 `CharacterCard` 独立实体。导入源格式、版本、警告和源文件名放在
一次性导入结果中即可；除非现有备份/诊断需要，不新增长期来源数据库。

## 6. 角色卡解析

新增纯解析服务，例如：

```text
lib/features/character_card/services/character_card_import_service.dart
lib/features/character_card/models/character_card_import_result.dart
```

### 6.1 支持格式

首版支持：

- `.json`：V1、V2 和 V3 基础字段；
- `.png`：SillyTavern Character Card PNG。

PNG 解析要求：

1. 读取 PNG tEXt/iTXt 元数据；
2. 优先读取 `ccv3`，不存在时读取 `chara`；
3. 解码 Base64 UTF-8 JSON；
4. 校验 JSON 根节点和可用角色字段；
5. PNG 本身作为头像复制到应用管理目录；
6. 限制文件和元数据大小，损坏输入不得导致卡死或内存失控。

优先检查现有 `image`、`archive` 依赖是否能够稳定读取所需 chunk；只有现有
依赖确实无法完成时才增加维护良好的专用依赖。不得靠扫描 PNG 二进制中的
任意字符串猜测角色卡 JSON。

### 6.2 导入结果

解析阶段不得直接写存储。`CharacterCardImportResult` 至少包含：

```text
assistantDraft
embeddedWorldBookDraft?
sourceFormat
specVersion
importedFields
ignoredFields
disabledWorldBookEntries
skippedWorldBookEntries
warnings
```

所有解析成功后再由协调服务保存助手、头像和世界书。任一步保存失败时不得留下
只有世界书没有助手、或只有助手没有绑定的半成品。

## 7. 内嵌世界书安全转换

复用 `WorldBookImportService` 和 `WorldBookProvider`，但角色卡内嵌世界书需要
“角色卡安全模式”，不得改变当前独立世界书导入的既有兼容行为。

规则如下：

1. 为导入世界书和条目生成新的 Kelivo UUID，避免覆盖已有数据；
2. 世界书名称优先取 `character_book.name`，否则使用“角色名 - 世界书”；
3. 保存成功后自动加入新 RP 助手的 active world-book IDs；
4. 支持普通文本主关键词、常驻条目、启用状态、顺序、大小写、扫描深度和当前
   Kelivo 已能表达的注入位置；
5. `extensions.regex_scripts` 永不进入世界书；
6. 只有正则主关键词、没有普通关键词的条目可以保留正文，但默认禁用；
7. 同时含普通关键词和正则关键词时，只采用普通关键词，并报告已丢弃正则；
8. 依赖 secondary key、AND/NOT、概率、递归、group、sticky、cooldown、delay、
   vector、whole-word 或不支持注入位置才能正确工作的条目默认禁用；
9. 无法安全确定语义的条目宁可禁用并报告，不得降级为可能误触发的常驻条目；
10. 角色卡没有世界书时不创建空世界书。

这里的“禁用”只适用于角色卡导入生成的世界书条目。不要移除用户当前独立导入
世界书时已经支持的正则关键词能力。

## 8. UI 与交互

### 8.1 导入入口

在助手管理页增加“导入角色卡”命令，Android 文件选择器接受 `.png` 和
`.json`。导入成功后直接创建并选中新 RP 助手。

导入确认页或结果对话框至少显示：

- 助手名称和头像预览；
- 是否导入人物设定、开场白和世界书；
- 世界书总条目、启用条目、禁用条目和跳过条目数；
- 被忽略的 system prompt、示例对话、备选开场白、正则和插件内容；
- 警告和失败原因。

### 8.2 助手编辑页

普通助手保持原界面。RP 助手显示：

- 助手类型只读标识或明确的模式选择；
- 现有系统提示词；
- 人物设定多行编辑框；
- 开场白多行编辑框；
- “从未来上下文中排除历史推理”开关；
- 现有提示词预设选择器；
- 现有世界书绑定入口。

不新增聊天主界面按钮。移动端使用现有页面/Sheet 组件，桌面端不得使用
BottomSheet；图标使用 Lucide，文案通过 ARB 本地化。

## 9. 新对话开场白

新建对话后，如果当前助手是 RP 助手且开场白非空：

1. 用当前用户名称和角色名称展开 `{{user}}`、`{{char}}`；
2. 作为一条真实、持久化的 `assistant` 消息写入当前对话；
3. 显示方式与普通助手回复相同；
4. 后续每轮通过普通聊天历史发送；
5. 对同一 conversation ID 最多插入一次；
6. 切换回已有空对话、重建 Widget、失败重试和应用重启不得重复插入；
7. 普通助手、临时对话和现有 preset messages 行为要有明确测试，不得产生
   两套开场消息或意外持久化。

如果助手同时存在现有 `presetMessages`，必须定义并测试顺序。建议 RP 开场白
作为第一条 assistant 消息，旧 preset messages 随后按既有顺序插入；不要让
preset message 取代 RP 开场白。

## 10. 人物设定注入

新增独立 `ContextSource.characterPrompt`。人物设定只对 RP 助手生效，并作为
`system` 角色的独立规范消息进入生成管线。

推荐顺序：

```text
真实聊天历史
→ 删除历史推理的临时上下文副本
→ Kelivo 助手系统提示词
→ RP 人物设定
→ 记忆/搜索/快捷指令
→ 世界书触发与注入
→ 上下文裁剪
→ 已选提示词预设的 before/history/after 条目
→ 提供商适配
```

要求：

- 世界书扫描的聊天文本应是已经排除历史推理的上下文，防止思考内容误触发；
- 人物设定本身不作为世界书关键词扫描来源，首版不复刻 SillyTavern 的角色
  字段扫描；
- 未选择预设、未绑定世界书时仍正常工作；
- 普通助手的请求在结构上保持原行为。

## 11. 历史推理过滤

### 11.1 用户可见行为

开启后：

```text
数据库和备份       完整保留原始回复及推理
聊天界面           保持 Kelivo 当前推理卡片和展开/折叠行为
复制/导出          保持现有行为，不在本任务中改变
未来模型请求       历史 assistant 消息只发送最终正文
当前生成及工具续接 保留协议必需数据，直到该模型轮次完成
```

该功能节省未来请求的输入上下文 Token，不声称减少已经生成的当前回复 Token。

### 11.2 内联思考标签

复用 `ThinkingTagParser`，过滤 Kelivo 当前识别的标签和 channel 形式。不要维护
另一套不一致的正则。对发送副本使用 parser 的 `visibleContent`，不修改
`ChatMessage.content`。

必须覆盖：

- 多个思考块；
- 大小写变化；
- 空思考块；
- 未闭合思考块；
- 思考块前后正文；
- 不含思考标签的普通正文；
- 过滤后为空的 assistant 消息；
- 大消息性能和非灾难性复杂度。

### 11.3 结构化推理字段

仅删除 `content` 中标签是不够的。历史消息还可能携带：

- `reasoning_content`；
- `reasoning_details`；
- Claude `thinking` / `redacted_thinking` blocks；
- Gemini thought signature；
- Kelivo 保存的 reasoning segments 和 provider artifacts。

实现必须区分“已完成的历史轮次”和“当前正在续接的同一模型轮次”：

1. 已完成历史轮次不发送可读 `reasoning_content`；
2. 已完成历史轮次不发送可读 `reasoning_details` 文本；
3. 当前 `processingMessageId` 对应的工具调用续接保留现有行为；
4. Claude 已完成工具轮次可以过滤 `thinking`/`redacted_thinking` 块，但必须
   保留合法的 `tool_use`/`tool_result` 配对和最终文本；
5. Gemini function calling 所需 `thoughtSignature` 属于协议签名，不等同可读
   推理正文；协议要求时可以保留；
6. OpenRouter/Claude 格式的签名信息不得在不理解结构的情况下用字符串正则
   改写；
7. 如果某提供商无法在删除推理后合法重放已完成工具轮次，优先保留最小协议
   制品并记录原因，而不是破坏请求；
8. 不得修改现有的本地持久化 reasoning 数据。

建议把过滤策略放在规范 API 消息构建层，并向提供商适配层传递明确策略，而
不是在 UI、流式 decoder 或数据库写入时删除。`processingMessageId` 已进入生成
准备流程，应作为保护当前工具轮次的依据。

## 12. 分阶段实施

### 阶段 0：基线与冲突检查

- 完整阅读 `AGENTS.md`、本计划和现有提示词预设计划；
- 检查当前分支、`git status` 和未提交预设功能；
- 不重置、不切走、不覆盖现有改动；
- 运行角色相关、世界书、消息构建和提供商兼容测试，记录基线。

完成标准：确认提示词预设功能仍在且测试通过，明确已有失败与本任务无关。

### 阶段 1：模型和纯角色卡解析

- 扩展 Assistant 模型；
- 实现 JSON V1/V2/V3 归一化；
- 实现 PNG `ccv3`/`chara` 提取及限制；
- 生成人物设定和开场白 draft；
- 生成详细导入报告；
- 添加脱敏 JSON 和程序生成的最小 PNG fixture 测试。

完成标准：无 UI、无持久化也能通过纯单元测试验证所有字段取舍和错误输入。

### 阶段 2：内嵌世界书与导入协调

- 增加角色卡安全转换模式；
- 转换、禁用和报告不支持条目；
- 保存助手、头像、世界书和助手绑定；
- 处理失败回滚、重复 ID、复制和删除引用；
- 接入备份/恢复、设置验证和合并。

完成标准：导入后重启应用，RP 助手、头像、世界书和绑定保持一致，无半成品。

### 阶段 3：UI 与开场白

- 增加角色卡文件选择和导入报告；
- 增加 RP 助手字段编辑和过滤开关；
- 新对话仅插入一次开场白；
- 完成移动端、桌面端和中英文 UI；
- 验证与 preset messages、提示词预设和临时对话的组合。

完成标准：从 PNG/JSON 到可聊天 RP 助手的完整路径可用。

### 阶段 4：人物设定和内联推理过滤

- 注入人物设定并增加 Context Logger 来源；
- 在世界书扫描和上下文裁剪之前净化历史发送副本；
- 复用 `ThinkingTagParser` 删除内联推理；
- 确认 UI、数据库、导出和普通助手不变；
- 增加上下文日志与 Token 长度差异测试。

完成标准：历史 `<think>` 内容在任意后续轮次均不进入最终规范消息。

### 阶段 5：结构化推理与提供商兼容

- 处理 `reasoning_content`、`reasoning_details` 和 Claude thinking blocks；
- 用 `processingMessageId` 保护同一轮工具续接；
- 保留 Gemini 等协议要求的最小签名；
- 扩充 OpenAI 兼容、Claude、Gemini、Kimi、GLM 和 OpenRouter 聚焦测试；
- 对比开关关闭时的请求结构，确保无回归。

完成标准：已完成历史轮次没有可读推理正文，同一轮工具调用仍可合法续接。

### 阶段 6：回归与 Android Release

- 格式化、生成本地化、严格分析；
- 运行所有新增聚焦测试和完整测试；
- 在 Android 模拟器/真机导入 JSON 和 PNG；
- 验证开场白、人物设定、世界书触发和多轮推理过滤；
- 构建、安装并冒烟测试 Release APK。

完成标准：无新增 analyzer/test 回归，Release APK 可安装且键盘响应正常。

## 13. 必须覆盖的测试

### 角色卡

- V1、V2、V3 JSON 基础字段导入；
- PNG 只有 `chara`、只有 `ccv3`、两者同时存在时 V3 优先；
- 非 Base64、非法 UTF-8、非法 JSON、超大 chunk 和普通 PNG；
- 人物设定字段边界、空字段和占位符；
- `first_mes` 只写入一次；
- 被忽略字段从不进入 Assistant、WorldBook 或模型上下文；
- 导入报告统计准确；
- 头像复制、助手复制、删除和备份恢复。

### 世界书

- 无内嵌书时不创建；
- 普通关键词条目转换并自动绑定；
- regex-only 条目默认禁用；
- mixed keyword 丢弃正则但保留普通关键词；
- 高级条件条目默认禁用并报告；
- 不改变现有独立 SillyTavern 世界书导入行为。

### 上下文过滤

- 开关关闭时消息与基线结构等价；
- 普通助手默认不过滤；
- RP 助手默认过滤；
- 本地 content/reasoning 数据不变；
- UI 解析输入不变；
- 第 2、3、10 轮仍不发送第 1 轮思考；
- 世界书不被已过滤思考关键词误触发；
- `reasoning_content` 和可读 `reasoning_details` 不进入已完成历史；
- 当前工具调用的 OpenAI/Kimi/GLM reasoning echo 不被提前删除；
- Claude 工具块仍合法配对；
- Gemini function call 需要的签名仍存在；
- 过滤后空正文不会制造非法或连续角色错误；
- Context Logger 长度和来源反映实际发送内容。

### 组合回归

- RP 系统提示词、人物设定、世界书、提示词预设和聊天历史顺序；
- 普通助手、指令注入、记忆、联网、附件、工具和快捷回复无回归；
- 未选择提示词预设或世界书时正常发送；
- Android 文件选择、重启恢复和键盘性能。

## 14. 验证命令

先运行各阶段聚焦测试，最后执行：

```powershell
dart format lib test
flutter gen-l10n
dart analyze --fatal-infos lib test
flutter test
```

完整测试若命中 `AGENTS.md` 已记录的 Windows 路径分隔符等历史失败，必须列出
具体测试并证明与本任务无关。所有新增和受影响的聚焦测试必须通过。

## 15. Android Release 交付

遵守 `AGENTS.md` 中的 Android 要求：

- 只交付 Release APK，不用 Debug APK 做性能结论；
- 在 ASCII 路径 `E:\devtools\kelivo-apk-build` 构建；
- 必要时使用指定 JDK 17；
- 使用本机忽略的个人测试签名，不提交密钥或 `key.properties`；
- 执行 `flutter build apk --release`；
- 设备可用时执行 `adb install -r` 并完成多轮 RP 冒烟测试；
- 报告 APK 绝对路径、大小和 SHA-256。

## 16. 最终验收清单

- [ ] 普通助手行为不变。
- [ ] 可从 JSON V1/V2/V3 和 PNG 创建 RP 助手。
- [ ] 只导入人物设定、开场白、名称、头像和内嵌世界书。
- [ ] 角色卡 system prompt、示例、备选开场白、正则和插件未进入运行时。
- [ ] 开场白在每个新对话只出现一次。
- [ ] 内嵌世界书自动绑定，危险或不支持条目禁用并报告。
- [ ] 系统提示词与人物设定分开编辑和发送。
- [ ] RP 助手仍可使用一个现有提示词预设。
- [ ] 界面和本地数据完整保留推理。
- [ ] 任意未来轮次的上下文不再包含已完成历史的可读推理正文。
- [ ] 同一轮工具续接和必要协议签名没有被破坏。
- [ ] Context Logger 能验证人物设定和过滤后的真实上下文。
- [ ] 现有定制功能无回归。
- [ ] Release APK 已安装冒烟测试并提供路径、大小和 SHA-256。
