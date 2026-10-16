# Findr Prompt 设计

配套 `需求.md`。四段 prompt：**P1 录入解析**、**P2 查询理解 + 意图路由**、**P3 答案组织（L2）**、**P4 建议裁决（L3）**。

> **文案的唯一权威在代码** —— 模板常量在 `packages/findr_core/lib/prompts/templates.dart`，
> 拼装与注入在 `prompts/render.dart`。本文只记录**设计意图、行为约束与调用侧约定**，
> 不复制文案：改文案改代码，改设计改本文。

---

## 〇、通用约定

| 项 | 约定 |
| --- | --- |
| 输出 | 一律要求纯 JSON，**不用 markdown 代码块**；客户端做容错解析（提取首个 `{` 到末个 `}`、修复截断、schema 校验） |
| 温度 | 0 ~ 0.2（结构化任务，不要发挥） |
| 语言 | 全部中文；字段名固定英文 |
| 变量注入 | `{{categories}}` `{{locations}}` `{{transcript}}` 等，由 `render.dart` 渲染；找不到的占位符换成**空串** |
| 不依赖 | function calling / JSON mode（各家支持度不一致），靠 prompt 约束 + 客户端容错 |

**位置树注入策略**：位置节点可能上百个，全量注入浪费 token 且干扰选择。只注入**一级 + 二级**（房间 → 家具），约 20~50 条；三级容器不注入，由用户在 UI 上补选，或模型猜出来后在 `path_suggestion` 里给出（实现：`formatLocationsForPrompt`）。

**图片顺序语义**：不限制张数。录入引导建议首张拍全貌、后续拍局部与特写，但这只是引导而非约束；模型按用户拍摄 / 选择顺序理解空间层级，多图（如流程截图）时顺序即用户选择顺序。

---

## 一、P1 · 录入解析（图片 + 文本 → desc + 结构化字段）

**模板**：`templates.dart` 的 `p1System` / `p1Schema` / `descRules` / `askRules` / `p1Fewshot` / `p1FewshotTextOnly` / `p1User` / `p1TextOnlyOff` / `p1TextOnlyUnsupported`。
**拼装**：`buildP1System`（system = 模板 + schema + 两条规则 + 示例 + 仅文本追加块）、`buildP1User`、`buildRegenerateDescUser`。
**调用方**：`pipeline/capture.dart`（录入理解）、`pipeline/edit.dart`（重新生成 desc）。

### 设计要点

- **没有「结构类型」**：不定义 `item / todo / procedure` 来约束 path 与 steps 的必要性 —— 判定为过度设计（对检索零影响、又和分类一一对应）。理由见 `技术设计.md` 3.1。
- **path 的判定与落库分工**：模型只给判断结果（复用已有位置层级 / 直接给出完整路径），代码侧 `ensurePath` 负责命中复用、缺失新建 —— 提示词与代码不能互相矛盾。
- **「借给谁 / 什么时候要 / 多久一次」没有独立字段**（不设 `related_person` / `due_at` / `cycle`），**如实写进 desc 就是正确做法** —— 「梯子借给隔壁老王家了，说下周还」这样写，日后搜「梯子」或「老王」都能命中。
- **`steps` 由模型输出纯文本数组**；客户端入库时包装为 `[{text, done: false}]`（见 `需求.md` 八），勾选状态不经过模型。
- **`path_matched` / `path_suggestion` 解析不做兜底**：类型不对 ⇒ 整次解析失败（有意保留的行为，别「顺手」补默认值，见 `parse/schema.dart` 头部）。

### user 消息组装

- 口述原文按 `p1User` 渲染；无文字时替换为 `（本次没有文字输入，请仅根据图片判断。）`。
- 图片以各 Provider 支持的方式附带，位于文本之前。
- **不送图片的情况**见下方「仅文本版」：① 用户关闭了图片分析开关；② 模型不支持图片。两者的提示文案不同。
- 「无文字 + 不送图片」= 无任何信息源，客户端直接拦截，不发起调用（`capture.dart`）。

### 仅文本版（两种情况）

**A. 用户关闭图片分析（主动选择，省 token）** → system 追加 `p1TextOnlyOff`。
**B. 模型不支持图片（能力缺失）** → system 追加 `p1TextOnlyUnsupported`。

两种模式下 few-shot 一并换成 `p1FewshotTextOnly`（`buildP1System` 按 `TextOnlyMode` 选择）：示例不含图片、desc 只依据文字 —— 否则「不要猜测图片内容」的约束会和带图示例互相打架。

> 二者的区别要体现在 UI 上：A 是用户可控的、随时可「补分析图片」；B 需要引导用户换模型，图片分析开关置灰锁定。

### 重新生成 desc（编辑闭环）

用户手改过结构化字段之后，可触发一次「重新生成描述」。它**复用 P1 的 system**（走仅文本版 A，因为不带图片），只在 user 消息末尾追加一段既定事实（`buildRegenerateDescUser`）：

- 只列**有值**的行（实体名 / 位置 / 标签 / 步骤）；一行都没有时不追加。
- **客户端只取回 `desc`，其余字段一律以用户编辑后的为准**。
- 与「补分析图片」的区别：那个会带图重跑并**覆盖**结构化字段，需要二次确认；这个是纯文本调用，便宜且不覆盖。

### 解析失败重试

首次响应 JSON 解析失败时**原样再调一次**，仅在 system 末尾追加一句「只输出一个合法 JSON 对象」；仍失败则该条进入待整理（`capture.dart`）。

---

## 二、P2 · 查询理解（口语 query → 本地检索条件 + 意图路由）

**模板**：`templates.dart` 的 `p2System` / `p2OutputSchema` / `p2Rules` / `p2Fewshot`。
**拼装**：`buildP2System`（system = 模板 + schema + 规则 + 示例，并注入已有分类与位置）。
**调用方**：`search/service.dart` 的 `searchCards`。

### 设计要点

- **P2 的核心职责是判 `mode`。** 定位题（我护照放哪了）与推理题（出国玩该带什么）需要**完全不同的输入**：前者的答案在库里躺着，走本地字面检索；后者的答案要靠常识把情景与库存连起来，走「整库清单 → P4 裁决」。见 `需求.md` 5.3。
- **P2 看不到记忆卡片内容**，不得把具体物品名当关键词输出 —— 它只把 query 翻译成检索条件，命中的活由本地 FTS 干。
- **判不准时一律选 locate**：误判代价不对称，字面检索至少还能给出字面命中的东西。

### 输出字段与消费方

| 字段 | 消费方 |
| --- | --- |
| `mode` | 路由：locate → 本地字面检索；advise → P4 裁决（跳过一切 SQL） |
| `intent` | `unknown` ⇒ 不做条件检索（`buildSearch` 返回 null，UI 提示换说法） |
| `keywords` / `synonyms` | 拼成本地 FTS5 / LIKE 表达式；别名表命中会再补一轮同义词（`withSynonyms`） |
| `category` / `path_prefix` / `time_hint` | 结构化字段过滤（不参与全文匹配） |
| `match_mode` | `any` 默认；`all` 仅当用户明确并列多个条件 |
| `scenario` / `aspects` | advise 专用：`scenario` 锁裁决范围，`aspects` 做整库清单的相关度排序（`inventory.dart`） |

### 客户端行为

- `mode = "locate"`：按 `intent` / keywords 走本地检索。`intent = unknown` 或 keywords 为空时**用原始 query 直查 FTS** —— 「配了模型但模型没听懂」不能比「压根没配模型」还不可用，同一件事不该有两条路。
- `mode = "advise"`：跳过字面检索，把整库清单交给 **P4**（见下节）。对这类问题字面检索**必然 0 条**，不是参数问题。
- `mode` 缺失时缺省为 `locate`，与没有这个字段时完全一致（老模型不会因此变差）。
- 查询理解调用失败或无网络时，跳过扩展、用原始 query 直查 FTS（`需求.md` 5.3 L1 兜底）。
- **硬过滤逐级放宽**（`builder.dart` 的 `relaxations`）：去 category → 去 path_prefix/time_hint → all 转 any。这些是模型顺手加的约束，猜错会把正确答案整批**静默**剔掉；放宽只跑本地 SQL，不额外调模型。

---

## 三、P3 · 答案组织（L2，仅 top-8 命中片段）

**模板**：`templates.dart` 的 `p3System` / `p3Schema` / `p3InputTemplate`。
**拼装**：`buildP3System` / `buildP3Input`。
**调用方**：`search/answer.dart` 的 `answerFromCards`；触发时机是本地无结果或用户手动触发（`search.autoAnswer` 打开后每次搜索都跑，默认关）。

### 输入格式

每张命中卡片压成一个片段块（`formatSnippets`）：块首 `[序号] id=<卡片 id>`，随后按需带
位置 / 实体 / 描述（截断 240 字）/ 原文（截断 160 字，仅当与描述不同）/ 记录时间（YYYY-MM-DD）。

- 最多 `l2MaxSnippets = 8` 条；**永不发送全库**（`需求.md` 5.3 的硬约束）。
- 空命中时片段替换为 `（没有命中任何片段）`，调用**仍然发出** —— P3 的约束是「片段不足就说没找到并说明缺什么线索」。
- `id` 必须带上：`hit_ids` 要靠它对回来做高亮；模型编出来的 id 一律丢弃。

### 输出

`answer`（口语化，≤120 字）/ `hit_ids` / `suggest`（可选的一句建议）。

---

## 四、P4 · 建议裁决（L3，整库清单 → 挑哪些 / 还缺什么）

只在 `mode = "advise"` 时调用。与 P3 的差别是**根本性的，不能合并成一个 prompt**：

| | P3 答案组织（L2） | P4 建议裁决（L3） |
| --- | --- | --- |
| 输入 | 已命中的 top-8 片段 | **整个记忆库**的条目清单 |
| 约束 | 不得补充片段之外的任何信息 | **必须用常识判断**那个场合用不用得上 |
| 回答什么 | 「你要找的东西在哪」 | 「你该带哪些、还缺什么」 |

> 「出国 → 护照」是**世界知识**，既不是字面相似度，也不是向量相似度能替代的。所以这一层的输入必须是**库存本身**：模型得先知道你有什么，才谈得上替你想。把两件事塞进同一个 prompt，只会让两条路都变弱。

**模板**：`templates.dart` 的 `p4System` / `p4Schema` / `p4InputTemplate`。
**拼装**：`buildP4Input`。
**调用方**：`search/advise.dart` 的 `adviseFromInventory`（由 `service.dart` 的 `_adviseSearch` 触发）。

### 清单生成（`search/inventory.dart` 的 `buildInventory`）

- 每张卡取 `实体 / 分类 / 位置 / 简述(60 字)`，表头一行 `序号 | id | 实体 | 分类 | 位置 | 简述`。
- **先按相关度排序，再截断**：terms 取 P2 的 `aspects` + `scenario` + 用户原句，本地子串打分（实体 6 / 标签 4 / 分类 3 / 位置 2 / 描述+原文 1，4 字以上的词加倍），排完再取前 `inventoryLimit = 200`。**纯本地，不额外调用模型。** 直接取 `created_at DESC` 的前 200 条，等于把「最近的」当成「最相关的」—— 库一大，去年记的护照正好被截在 200 之外，而它恰恰是这条通道存在的理由；提示词一个词都没碰上时（P2 判错情景）全部同分 ⇒ 退回纯时间倒序，不会更差。
- `inventoryPool = 2000` 是**排序候选池**的上界（给「整库读进内存」一个界），**不是外发上界**。
- 超出时**不静默截断**：末尾写明「全库共 N 条，此处只列出最相关的 M 条 —— 可能不全」，让模型有机会自己说「可能还有没列出来的」。

### 三档与理由

- `picks` / `maybe` 也接受**只回 id 字符串**（不带 `why`）—— 让「结构更完整」不成为一次解析失败的理由。
- **为什么是三档而不是两档**：二分类会逼模型在「误删对的」和「全留成噪音」之间二选一。「插线板」就是那个分界样本 —— 去欧标/英标国家它是必需的，去日韩则未必；助手说得出「这个看你情况」，数据库只会二选一。
- 这里没有 `suggest`：P3 的 `suggest` 是「还能问什么」，`missing` 是「你还缺什么」—— 后者才是这个场景里真正有价值的信息。

### 客户端行为（`search/advise.dart`）

- **只认清单里存在的 id**：模型编出来的 id 一律丢掉，否则列表会指向不存在的卡。
- **同一张卡同时进了两档时以 `picks` 为准**，避免列表里出现两张一样的卡。
- `picks` 与 `maybe` 的顺序即列表顺序（必需在前）。
- **一条都没挑中时**：顺手跑一次零成本的本地字面检索；命中就把这批结果一并给出（`advice` 仍保留，答案与 `missing` 照常显示）。
- 裁决调用失败 ⇒ 退到字面兜底并标记 `usedFallback`。
- **空库不发这次调用**：没有任何库存，「你需要什么」无从谈起。

---

## 五、测试与验证

真机验收步骤见 `开发指南.md` 第六节。**模型准不准不设离线指标** —— 靠真机实际使用发现。
文案渲染断言见 `packages/findr_core/test/prompts/render_test.dart`。
