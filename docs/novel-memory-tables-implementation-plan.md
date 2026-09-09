# Kelivo 小说 / RP 记忆表格实施方案

## 1. 目标与结论

目标是在长篇小说或 RP 对话中，用结构化记忆保存人物、性格、关系、事件和当前状态，并在后续请求中用这些记忆替代已经被可靠覆盖的冗长历史，从而降低上下文长度，同时保证原始正文仍可查看、编辑、备份和恢复。

该功能可以实现，而且 Kelivo 已有一部分可复用基础设施。但不应把现有“用户长期记忆”直接改成小说记忆，也不应原样复制 SillyTavern 插件让主模型在正文中输出任意 `tableEdit` 命令的做法。推荐新增独立的“故事记忆”领域，在后台使用独立记忆模型生成严格结构化变更，验证后事务写入；只有成功、连续且来源仍有效的记忆覆盖范围，才允许从发送给模型的历史副本中省略。

最重要的产品边界：

1. 原始消息、正文、思考内容和附件永远保留在数据库、界面、导出和备份中。
2. “替换历史”只发生在每次 API 请求的上下文副本里，不删除或改写真实聊天记录。
3. 记忆表格的结构模板绑定助手，实际记忆数据默认绑定 conversation，避免不同小说、平行剧情或重开对话互相污染。
4. 任一提取、解析、校验、保存或版本一致性检查失败时，宁可保留旧历史，也不能误删未被记忆覆盖的情节。

## 2. 调研对象与真实机制

### 2.1 SillyTavern 记忆增强表格插件

中文社区通常所说的“酒馆记忆表格”主要指第三方插件 [muyoou/st-memory-enhancement](https://github.com/muyoou/st-memory-enhancement)，不是 SillyTavern 核心功能。本次审计版本为 commit `3ae69c9fe4c8cc361560188df667ab713be82828`。

其主流程是：

```text
当前表格 + 最近聊天 + 编辑规则
                ↓
模型生成 <tableEdit> 中的 insertRow/updateRow/deleteRow
                ↓
插件解析并执行行级操作
                ↓
表格快照写入聊天元数据/消息版本
                ↓
下一次请求按指定 role 和 depth 注入最新表格
```

源码证据：

- [`index.js`](https://github.com/muyoou/st-memory-enhancement/blob/3ae69c9fe4c8cc361560188df667ab713be82828/index.js#L221-L339) 解析并执行 `insertRow`、`updateRow`、`deleteRow`。
- [`index.js`](https://github.com/muyoou/st-memory-enhancement/blob/3ae69c9fe4c8cc361560188df667ab713be82828/index.js#L498-L518) 把表格操作附加到 assistant 消息及其 swipe 版本。
- [`index.js`](https://github.com/muyoou/st-memory-enhancement/blob/3ae69c9fe4c8cc361560188df667ab713be82828/index.js#L524-L616) 按 system/user/assistant role 和 depth 注入表格。
- [`core/manager.js`](https://github.com/muyoou/st-memory-enhancement/blob/3ae69c9fe4c8cc361560188df667ab713be82828/core/manager.js#L120-L150) 以 `chatMetadata.sheets` 保存当前聊天域表格。
- [`separateTableUpdate.js`](https://github.com/muyoou/st-memory-enhancement/blob/3ae69c9fe4c8cc361560188df667ab713be82828/scripts/runtime/separateTableUpdate.js) 支持回复后使用主或副 API 独立填表，并过滤正文中的 think/tableEdit 标记。
- [`absoluteRefresh.js`](https://github.com/muyoou/st-memory-enhancement/blob/3ae69c9fe4c8cc361560188df667ab713be82828/scripts/runtime/absoluteRefresh.js) 支持整表整理、重建和确认。

这个机制的优点是表结构可配置、用户可直接编辑、当前状态每轮可重新注入。缺点是模型可能误覆盖稳定设定，模型格式错误也可能破坏表格或正文解析。项目仍有用户请求“锁定行以防 AI 覆盖”的 [Issue #152](https://github.com/muyoou/st-memory-enhancement/issues/152)，以及整表整理清空聊天域模板属性的 [Issue #211](https://github.com/muyoou/st-memory-enhancement/issues/211)。这些问题说明“模型输出即执行”和缺少强事务边界不适合直接照搬。

### 2.2 OmniTavern 可借鉴的改进

OmniTavern 已把记忆表格发展成更完整的独立领域。本次审计版本为 `0.7.2`，commit `74eea165f1784746d81cde00e578a6a88e855673`。

值得借鉴的部分：

- 模板与行数据分离：模板定义表、列、作用域和更新策略；行数据独立存入 SQLite。
- RP 专用表：重要人物、任务、分段摘要和总体大纲与普通聊天表分开。
- 结构化操作既支持单独填表，也支持确认后执行。
- 每条摘要记录覆盖的轮次范围，并计算覆盖空洞；存在空洞时保留相应原始历史。
- 按 `state / recent / mid / far / recall` 分配上下文预算，而不是把所有记忆无上限注入。
- 摘要可再次滚动压缩，但保留来源区间并集，不能用一个 `min-max` 范围掩盖中间空洞。
- 支持置顶、优先级、启用状态、注入审计和回放测试。

OmniTavern 的实现说明了“表格用于保存状态，摘要用于覆盖历史”应当是两类数据。只保存人物表和事件表，还不足以证明某段原文可以安全省略；必须另有带来源范围的情节摘要和覆盖检查。

### 2.3 Kelivo 当前基础

Kelivo 已有 V2 长期记忆管线：后台队列、独立记忆模型、按轮触发、gatekeeper、extractor、Smart Add、追踪日志、失败重试、水位线、消息版本折叠和模型可见历史过滤。消息构建阶段也已有记忆快照注入、冻结和刷新机制。

现有记忆数据只有 `identity / workflow / voice / instruction` 四类，语义是“用户跨会话长期偏好”；作用域为 global 或 assistant。它不适合承载某一本小说的角色状态和事件，否则不同 conversation 会互相污染，现有 Smart Add 的去重/合并也会错误地把不同时间点的事件合并。

因此建议：复用运行基础设施，不复用现有 `MemoryEntry` 业务模型。新增独立的 Story Memory 数据表、Repository、Provider、Pipeline 和消息构建段。

## 3. 推荐的数据设计

### 3.1 作用域

```text
Assistant
└── StoryMemoryTemplate / StoryMemorySettings
    └── Conversation A
        ├── Character rows
        ├── Character state rows
        ├── Relationship rows
        ├── Event rows
        ├── Plot summary rows
        └── Coverage checkpoints
    └── Conversation B
        └── 独立数据，不自动继承 A
```

助手保存表格开关、默认模板、更新频率、近期原文保留轮数和预算。实际表格数据归 conversation。未来若需要同一小说跨 conversation 续写，应通过显式“复制/关联故事记忆库”实现，不能默认共享。

### 3.2 第一版固定表

第一版建议固定表结构，不先开发任意自定义列。固定结构更容易生成严格 JSON Schema、做字段锁定、验证更新规则和保证 Android UI 可用。

#### 角色档案 `characters`

保存相对稳定的设定：

- `characterId`
- `name`
- `aliases`
- `identity`
- `appearance`
- `coreTraits`
- `motivation`
- `background`
- `importance`
- `lockedFields`
- `sourceMessageIds`
- `updatedAt`

`name`、`identity`、`coreTraits` 等字段默认允许用户锁定。锁定后仍注入给记忆模型用于识别，但任何模型 patch 都不得修改。

#### 角色状态 `character_states`

保存会随剧情变化的信息：

- `characterId`
- `location`
- `physicalState`
- `emotionalState`
- `currentGoal`
- `knowledge`
- `possessions`
- `present`
- `effectiveAtOrder`
- `sourceMessageIds`

稳定性格与当前情绪必须分开。前者很少更新，后者可每轮变化，混在同一字段会导致模型把临时表现误写成永久性格。

#### 关系 `relationships`

- `fromCharacterId`
- `toCharacterId`
- `relationType`
- `attitude`
- `trust`
- `changeReason`
- `effectiveAtOrder`
- `sourceEventIds`

#### 事件 `events`

- `eventId`
- `chapterOrTime`
- `participants`
- `location`
- `cause`
- `summary`
- `result`
- `consequences`
- `unresolvedClues`
- `importance`
- `sourceStartOrder`
- `sourceEndOrder`
- `sourceMessageIds`

事件以追加为主。模型不得通过普通更新静默改写旧事件；纠错应生成 supersede/retcon 关系并保留变更记录。

#### 情节摘要 `plot_summaries`

- `summaryId`
- `sourceStartOrder`
- `sourceEndOrder`
- `sourceMessageIds`
- `sourceDigest`
- `summary`
- `keyEntities`
- `unresolvedThreads`
- `createdAt`
- `supersededBy`

这是允许替代旧历史的核心表。人物、关系和事件表只提供事实，不承担“完整覆盖了一段剧情”的证明。

#### 覆盖检查点 `story_memory_checkpoints`

- `conversationId`
- `startOrder`
- `endOrder`
- `selectedVersionDigest`
- `patchId`
- `status`
- `createdAt`

只接受从上一个成功检查点连续向前推进的区间。任何区间空洞、消息版本变化或来源摘要缺失都会使后续上下文压缩 fail-open，即保留原文。

### 3.3 变更日志

每次模型更新先创建不可变 `story_memory_patch`：

```json
{
  "schemaVersion": 1,
  "conversationId": "...",
  "sourceStartOrder": 21,
  "sourceEndOrder": 28,
  "sourceDigest": "...",
  "operations": [
    {"op": "upsertCharacterState", "characterId": "char_...", "fields": {}},
    {"op": "appendEvent", "row": {}},
    {"op": "appendPlotSummary", "row": {}}
  ]
}
```

禁止模型直接输出 SQL、JavaScript、函数调用字符串或自由列名。应用只接受白名单 operation 和字段；限制操作数、字符串长度、数组长度和总响应大小。验证通过后，在一个 Drift transaction 中写入 patch、行数据和 checkpoint，最后才推进水位线。

## 4. 运行流程

### 4.1 后台提取

推荐默认在 assistant 回复完整落库后异步触发，使用独立记忆模型，不让主回复携带隐藏的填表标记：

```text
assistant 回复完成
→ 读取上次成功 checkpoint 之后的已选版本消息
→ 先做历史思考/剧情选项过滤
→ 达到 N 轮或手动“整理记忆”时进入队列
→ 记忆模型输出严格 JSON patch
→ schema 校验、锁定检查、引用检查、来源摘要检查
→ Drift transaction 写入
→ 成功后推进 checkpoint；失败则保留原 watermark 并可重试
```

建议默认每 4 个 user-assistant 回合整理一次，窗口最多 8 回合；用户可改为 1、2、4、8 或仅手动。独立调用失败不能影响主回复，也不能使聊天发送失败。

现有 `MemoryPipelineService` 的队列、临时对话跳过、流式消息跳过、失败追踪和选中版本折叠逻辑可以提取为共享基础，或由新的 `StoryMemoryPipelineService` 复用同样模式。不要把故事条目传入现有 `MemorySmartAdd`。

### 4.2 写入规则

校验器必须执行以下规则：

1. 锁定行/字段可读不可写；涉及锁定字段的操作整项拒绝并记录原因。
2. 角色引用必须指向已存在角色，或在同一 patch 中先创建。
3. 事件默认只追加，删除必须来自用户手动操作。
4. patch 的 source digest 必须与当前选中消息版本链一致。
5. 必须包含覆盖整个来源窗口的 `plot_summary`，否则事实表可以更新，但 checkpoint 不推进，旧历史不能省略。
6. 任一数据库阶段失败整笔回滚，不留下半张表或虚假覆盖范围。
7. 自动写入后保留 patch 日志和“一键撤销本次整理”；用户手动编辑也产生本地 patch。

第一版可以默认自动提交，并在记忆页显示“最近一次更新”。高风险用户可开启“每次确认”，显示新增、修改和被拒绝的字段后再提交。

### 4.3 发送上下文时替换旧历史

推荐固定顺序：

```text
原始数据库消息
→ 折叠到当前选中的回复版本链
→ 过滤历史思考和 RP 剧情选项，只保留模型可见正文/协议制品
→ 保留最近 K 个完整回合
→ 验证更早前缀是否被连续 checkpoint 覆盖且 digest 仍有效
→ 省略已覆盖前缀；覆盖空洞和失效区间继续保留原文
→ 注入故事记忆快照
→ 结合当前输入、近期历史和记忆实体扫描世界书
→ 执行现有上下文裁剪并发送
```

故事记忆快照建议作为单独 system 段注入，位置在角色卡/系统设定之后、近期聊天之前。应明确优先级：用户当前指令和近期正文高于自动记忆；锁定人物设定高于自动推断；发生冲突时模型不得自行改写锁定设定。

世界书是静态或条件触发的背景设定，故事记忆是当前剧情状态，两者应同时存在。世界书扫描不能继续依赖已经被省略的全部旧原文，否则旧关键词会永久误触发；建议扫描“当前输入 + 近期原文 + 注入的记忆实体/关键词”。

### 4.4 上下文预算

第一版先采用容易验证的明确上限：

- 始终保留最近 8 个完整回合原文。
- 故事记忆快照默认最多占模型输入预算的 20%，同时设绝对上限。
- 角色当前状态和未解决线索优先，其次高重要度事件，再其次较远摘要。
- 锁定/置顶条目优先，但仍计入预算。
- 条目被截断时按整行舍弃，不能从中间截断字段形成错误事实。
- 预算不足时优先增加近期原文，不能为了塞入更多远期记忆而删除未覆盖历史。

第二阶段再实现 OmniTavern 类似的 `state / recent / mid / far / recall` 动态配额和关键词召回。第一版不需要向量数据库或 embedding；它们解决“从大量记忆中找相关条目”，不是保证历史压缩正确性的前提。

## 5. 界面设计

### 5.1 助手设置

在助手的“记忆”区域增加独立卡片：

- 启用小说 / RP 记忆表格
- 自动整理开关
- 记忆模型
- 整理频率
- 最近原文保留回合数
- 记忆注入预算
- 写入前确认
- 打开当前对话记忆

普通助手也可启用，但 RP 助手默认展示该能力。现有“用户长期记忆”保持独立开关和独立说明。

### 5.2 对话记忆页

移动端使用全屏页面，桌面端使用对话框/侧栏，包含：

- `角色`、`状态`、`关系`、`事件`、`情节摘要` 五个标签页。
- 新增、编辑、归档和搜索。
- 行/字段锁定及置顶。
- 每条记录的来源范围，点击可跳到原消息。
- 最近 patch 的变更详情、失败原因和撤销。
- “立即整理”“从指定位置重建”“清空本对话记忆”。
- 覆盖状态：已整理到哪一条消息、是否存在空洞、下一批待处理数量。
- 上下文预览：本轮会注入哪些表、保留哪些原文、预计 token 数。

删除与重建必须二次确认。清空故事记忆后应自动恢复发送完整历史，不能继续沿用旧 checkpoint。

## 6. 消息编辑、重生成和分支

这是功能正确性的高风险区域：

- assistant swipe/重生成切换到另一版本时，从首个发生变化的 message order 起，相关 checkpoint 和派生记忆标记为 stale。
- 编辑被覆盖范围内的 user 或 assistant 消息时采用相同失效规则。
- stale 数据可暂时保留供审计，但不得注入，也不得用于省略原文。
- 后台从最近一个仍有效的连续 checkpoint 开始重建。
- 如果无法证明版本链未变化，就保留原历史，不尝试猜测哪些记忆仍然正确。

这应直接复用 Kelivo 现有的消息 group/version selection 语义，并为每个 checkpoint 保存选中版本链 digest。

## 7. 备份、恢复与隐私

所有新表、patch、锁定状态、checkpoint、助手设置和模板都必须进入 Kelivo 备份/恢复，并提供 schema 版本。恢复应先导入数据再校验覆盖链；校验失败时保留表格但禁用历史替换。

记忆模型调用会发送相应剧情窗口，应沿用 Kelivo 当前 provider 隐私边界。日志默认只保存必要的状态和长度；完整 prompt/response 仅在用户明确启用 Context Logger/调试追踪时记录。

## 8. 分阶段实施

### 阶段 1：领域模型与持久化

- 确定固定表字段和 JSON patch v1 协议。
- 新增 Drift 表、索引、Repository 和事务 API。
- 新增助手级设置与 conversation checkpoint。
- 接入备份/恢复和 schema 迁移。
- 暂不调用模型，也不改发送上下文。

验收：CRUD、锁定、patch 原子提交、失败回滚、备份往返和不同 conversation 隔离全部通过。

### 阶段 2：提取器与后台管线

- 新增严格 JSON Schema、提示词、解析器和验证器。
- 接入独立记忆模型、队列、频率、手动整理、重试和追踪。
- 建立来源 digest、连续 checkpoint 和 stale 判定。
- 保持主聊天回复完全不受填表失败影响。

验收：假模型覆盖正常 patch、格式错误、超限、锁定冲突、外键错误、网络失败和事务故障；只有完整成功时推进 checkpoint。

### 阶段 3：上下文替换

- 在统一模型可见历史入口之后接入故事记忆覆盖计算。
- 保留最近 K 回合，省略已被连续有效摘要覆盖的前缀。
- 接入故事记忆快照、token 上限、上下文日志和世界书扫描输入。
- 所有改动只作用于发送副本。

验收：无记忆、覆盖完整、覆盖有洞、版本失效、纯思考消息、剧情选项、工具消息、附件和临时对话场景下均无误删。

### 阶段 4：管理界面

- 实现移动端全屏页和桌面端非 BottomSheet 界面。
- 表格浏览编辑、锁定、来源跳转、变更预览、撤销、重建、覆盖状态和上下文预览。
- 完成中英文 ARB、本地化和无障碍标签。

验收：小屏 Android 无溢出，键盘输入不卡顿，助手/对话切换不串数据，退出页面前编辑可靠保存。

### 阶段 5：性能与高级召回

- 情节摘要滚动压缩，保留原覆盖区间并集。
- 按重要度、时间、实体关键词做选择性召回。
- 引入 `state / recent / mid / far / recall` 动态预算。
- 数据量确实达到本地关键词搜索瓶颈后，再评估 embedding/RAG。

## 9. 测试矩阵

### 单元测试

- JSON patch schema、白名单、大小限制和恶意字符串。
- 每种操作的校验、锁定字段、事件追加规则和引用完整性。
- 来源 digest、连续区间、空洞合并、stale 失效和重建起点。
- token 预算、整行截断、置顶/重要度排序。
- 表格序列化、备份/恢复和数据库迁移。

### 集成测试

- assistant 完成回复后异步触发，不阻塞主回复。
- 独立模型失败、返回空内容、解析失败和数据库故障时不推进 checkpoint。
- 修改/重生成旧消息后，旧记忆不再注入且原文恢复发送。
- 与现有用户长期记忆、角色卡、提示词预设、世界书、思考过滤和 RP 剧情选项共同组装上下文。
- 当前工具续接、Claude tool blocks、Gemini thought signature 等协议制品保持不变。

### UI 与 Android 验收

- 创建两个助手、两个 conversation，确认故事数据完全隔离。
- 使用至少 100 回合的合成长篇对话测试滚动、搜索、整理、重建和冷启动。
- 对锁定性格制造相反模型 patch，确认写入被拒绝且界面提示原因。
- 制造一个覆盖空洞，确认对应原文仍出现在 Context Logger 的实际请求中。
- 确认已覆盖旧正文从请求中省略，但仍可在 UI、导出和备份中查看。
- 比较启用前后的实际输入 token；记录而不是只看字符估算。
- 构建 Release APK，`adb install -r`、冷启动、文件备份恢复和真机键盘性能验收。

## 10. 完成标准

满足以下条件才可宣布功能闭合：

1. 角色、状态、关系、事件和摘要能由用户编辑，也能由独立记忆模型可靠更新。
2. 锁定内容无法被模型覆盖；所有自动修改均可追溯和撤销。
3. 只有连续、有效、与当前回复版本链一致的摘要区间会替代旧历史。
4. 任意失败都不会损坏表格，也不会导致未覆盖正文从请求中消失。
5. 原始聊天、附件、思考、剧情选项、备份和导出数据保持不变。
6. Context Logger 能明确显示故事记忆、近期原文、被省略范围、覆盖空洞和 token 使用。
7. 聚焦测试、严格静态分析和 Android Release 手工验收通过；全量基线失败被准确区分。

## 11. 推荐的第一版范围

为降低一次开发过大的风险，第一版只做：固定五表、conversation 级数据、独立模型每 N 回合整理、严格 JSON patch、字段锁定、来源与连续 checkpoint、最近 8 回合原文、发送副本替换、基础编辑页、备份恢复和 Context Logger。

第一版暂不做：任意自定义模板、SillyTavern 表格模板导入、跨 conversation 自动共享、向量检索、复杂概率召回、脚本执行和模型在主回复中内嵌填表命令。等第一版通过长篇实测后，再决定是否增加这些能力。
