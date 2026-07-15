# ArkTavern 开发计划

Version: 0.1
Date: 2026-07-15

---

## 1. 总则

- 本计划将 ArkTavern 拆分为 Phase 0 ~ Phase 8 共 9 个阶段。
- 每个阶段遵循"先稳定基线 → 再叠加功能"原则,Phase N 必须满足验收标准后才能进入 Phase N+1。
- 每个阶段产出可独立验证、可独立回滚。
- 不创建空目录与占位文件,目录按阶段实际需求创建。
- 详细可执行任务见 `TODO.md`。

---

## Phase 0:工程审计与基础架构

### 目标
确认工程基线,搭建分层骨架与公共工具,完成两项关键技术 PoC(SSE 流式、安全存储)。

### 输入
- 纯净 HarmonyOS NEXT 6.1.x 初始工程
- AGENTS.md / ARCHITECTURE.md
- ArkTavern-Reference 参考资料

### 输出
- 基础工具模块:utils/(Logger / Uuid / Time)
- 网络核心骨架:network/core/(HttpClient 接口 + 错误模型)
- SSE 流式 PoC(可独立运行验证)
- 安全存储 PoC(huks 加密/解密 API Key)
- 分层目录就绪(models / services / storage / network / viewmodels / utils)

### 依赖
- 无外部依赖

### 风险
- SSE 增量回调在 @ohos.net.http 的实际支持情况未确认(可能需切换 rcp)
- huks API 在 API 23 的算法支持范围未确认(GCM 模式必须可用)
- ArkTS 严格模式对动态对象的限制

### 验收标准
- [ ] Logger 可分级输出且不泄露密钥
- [ ] SSE PoC 能对接任意 OpenAI 兼容端点并增量打印 token
- [ ] 安全存储 PoC 能加密保存一段文本并解密还原
- [ ] 工程可正常构建且 code-linter 无 error

### 建议任务拆分
1. 创建 utils/ 基础工具(Logger / Uuid / Time)
2. 创建 network/core/ 错误模型与 HttpClient 接口
3. SSE 流式接收 PoC(独立可验证)
4. 安全存储 PoC(huks)
5. 确立分层目录与导出约定

---

## Phase 1:模型配置与接口连通

### 目标
实现 Provider 配置管理、API Key 安全存储、OpenAI-compatible 非流式与流式请求,完成端到端"配置 → 请求 → 收到回复"链路。

### 输入
- Phase 0 的 HttpClient / SseParser / KeyStore
- SillyTavern src/endpoints/backends/chat-completions.js(参考请求体)
- SillyTavern public/scripts/openai.js(参考请求构造)

### 输出
- models/ProviderConfig、models/ChatMessage、models/ChatRequest
- storage/Preferences(当前选中 Provider 等)
- storage/KeyStore(多 Provider 密钥)
- network/providers/OpenAIProvider
- services/ModelService
- pages/ModelSettingsPage + viewmodels/ModelSettingsViewModel
- 最小验证页:输入配置 → 发送一句话 → 显示回复(流式)

### 依赖
- Phase 0 全部完成

### 风险
- 不同 Provider 的鉴权头差异(Authorization: Bearer vs x-api-key)
- 流式中断与错误恢复策略
- 网络权限声明(module.json5 需补充 ohos.permission.INTERNET)

### 验收标准
- [ ] 可保存多个 Provider 配置(Base URL / Model / 温度等)
- [ ] API Key 经 huks 加密存储,数据库与日志均无明文
- [ ] 可向 OpenAI 兼容端点发送非流式请求并解析回复
- [ ] 可向 OpenAI 兼容端点发送流式请求并增量渲染
- [ ] 网络错误/超时/鉴权失败有明确错误提示

### 建议任务拆分
1. 定义 Provider/Message/Request 数据模型
2. 实现 KeyStore(多密钥管理)
3. 实现 Preferences(设置项)
4. 实现 OpenAIProvider(非流式)
5. 实现 OpenAIProvider(流式,复用 Phase 0 SseParser)
6. 实现 ModelService
7. 实现模型设置页与最小验证页
8. 补充网络权限与明文流量配置(若需)

---

## Phase 2:基础聊天

### 目标
实现单角色聊天界面,支持消息发送、流式接收、消息列表渲染,内存态消息管理(此阶段不落库)。

### 输入
- Phase 1 的 OpenAIProvider 与 ModelService
- MiniTavern 聊天页 UX 参考(仅交互)

### 输出
- pages/ChatPage + viewmodels/ChatViewModel
- components/MessageBubble、components/ChatInput、components/StreamingIndicator
- services/ChatService(内存态)
- 临时角色(占位,Phase 3 替换为真实角色卡)

### 依赖
- Phase 1 完成

### 风险
- 长会话列表性能(LazyForEach)
- 流式渲染抖动与滚动定位
- 输入法遮挡

### 验收标准
- [ ] 可发送用户消息并收到流式 AI 回复
- [ ] 流式过程中 UI 不阻塞
- [ ] 消息列表可滚动且新消息自动定位到底部
- [ ] 可中断正在生成的回复

### 建议任务拆分
1. 定义内存态 ChatSession / Message 视图模型
2. 实现 ChatService(发送 / 接收 / 中断)
3. 实现消息气泡组件(用户 / 助手区分)
4. 实现输入区组件(含发送 / 停止按钮)
5. 实现 ChatPage 与流式渲染
6. 性能验证(长列表 LazyForEach)

---

## Phase 3:角色卡导入

### 目标
实现角色卡 JSON(V2/V3)解析与导入,角色信息可填充到聊天上下文(描述/人设/场景/首条消息)。

### 输入
- SillyTavern src/character-card-parser.js
- SillyTavern default/content/ 角色卡 JSON 样例
- MiniTavern 角色导入功能面参考

### 输出
- models/Character(V2/V3 字段映射到内部模型)
- parser/character/CharacterCardParser
- services/CharacterService(导入 / 列表 / 选中)
- pages/CharacterImportPage(从文件选择 JSON)
- pages/CharacterListPage(列表展示)
- 聊天页接入角色首条消息与描述

### 依赖
- Phase 2 完成
- 文件选择器(@ohos.file.picker)

### 风险
- V2 与 V3 字段差异兼容
- 字段缺失的容错
- 角色卡包含扩展字段(spec)的处理

### 验收标准
- [ ] 可从本地 JSON 文件导入 V2/V3 角色卡
- [ ] 导入失败有明确错误提示
- [ ] 角色列表可展示已导入角色
- [ ] 选中角色后聊天页使用其描述/人设/场景/首条消息

### 建议任务拆分
1. 定义 Character 内部模型(含 V2/V3 字段映射)
2. 实现 CharacterCardParser(JSON 解析 + 校验)
3. 实现文件选择与导入流程
4. 实现 CharacterService(内存态)
5. 实现角色列表页与导入页
6. 聊天页接入角色上下文

---

## Phase 4:本地数据库

### 目标
引入 HarmonyOS RDB,持久化角色、聊天、消息;替换此前内存态数据。

### 输入
- Phase 3 的 Character 模型
- Phase 2 的 ChatSession / Message
- ARCHITECTURE.md 的表结构定义

### 输出
- database/DbHelper(RDB 初始化 / 版本管理)
- database/migrations(建表脚本)
- repositories/CharacterRepository、ChatRepository、MessageRepository
- services 层切换为 Repository 访问
- 退出重进后数据不丢失

### 依赖
- Phase 3 完成
- @ohos.data.relationalStore(API 23 确认可用)

### 风险
- RDB 在 API 23 的 API 稳定性
- 大消息文本字段性能
- 索引设计

### 验收标准
- [ ] 应用重启后角色与聊天记录均保留
- [ ] 多会话可切换且互不干扰
- [ ] 消息增删改均落库
- [ ] 数据库迁移可重复执行不报错

### 建议任务拆分
1. 设计建表脚本(characters / chats / messages)
2. 实现 DbHelper 与初始化
3. 实现 CharacterRepository
4. 实现 ChatRepository / MessageRepository
5. Service 层切换为 Repository
6. 数据持久化验证

---

## Phase 5:Prompt 与宏系统

### 目标
实现完整的 Prompt 构建器与宏替换器,使发送给 AI 的上下文符合 SillyTavern 拼接规则。

### 输入
- SillyTavern public/scripts/openai.js、sysprompt.js、authors-note.js
- SillyTavern public/scripts/macros/*
- AGENTS.md 的 Prompt 顺序与宏清单

### 输出
- services/PromptBuilder(System→Char→Scenario→Lorebook→Examples→History→Input→Post)
- services/MacroReplacer({{user}} / {{char}} / {{description}} / {{scenario}} / {{personality}} / {{lastMessage}})
- models/PromptSegment
- utils/TokenCounter(简化估算)
- ChatService 接入 PromptBuilder

### 依赖
- Phase 4 完成
- Phase 3 的 Character(用于宏替换)

### 风险
- Prompt 顺序与 SillyTavern 细节差异
- 宏嵌套与递归替换边界
- Token 超限截断策略

### 验收标准
- [ ] 生成的 Prompt 顺序符合 ARCHITECTURE.md 定义
- [ ] 所有标准宏可正确替换
- [ ] Token 估算可给出近似值
- [ ] 超长历史可按窗口截断

### 建议任务拆分
1. 定义 PromptSegment 模型与顺序枚举
2. 实现 MacroReplacer(标准宏)
3. 实现 PromptBuilder(各段拼接)
4. 实现简化 TokenCounter
5. 历史消息窗口截断策略
6. ChatService 接入并端到端验证

---

## Phase 6:世界书与预设

### 目标
实现世界书(关键词匹配 / 优先级 / constant)与预设(采样参数 / 系统提示模板)。

### 输入
- SillyTavern public/scripts/world-info.js
- SillyTavern src/endpoints/worldinfo.js、presets.js
- SillyTavern default/content/ 世界书与预设样例

### 输出
- models/Lorebook / LorebookEntry
- parser/lorebook/LorebookParser
- services/LorebookService(扫描当前消息,激活条目)
- models/Preset
- services/PresetService
- PromptBuilder 接入 Lorebook 段
- 世界书与预设管理页

### 依赖
- Phase 5 完成

### 风险
- 关键词匹配算法复杂(含 AND/OR/NOT 组合)
- 递归扫描(本次仅实现单层,递归留待后续)
- 预设与 Provider 参数的字段映射

### 验收标准
- [ ] 可导入世界书 JSON 并解析
- [ ] constant 条目始终注入
- [ ] 关键词命中条目按优先级注入
- [ ] 可导入预设并应用到请求参数
- [ ] 世界书条目出现在 Prompt 的 Lorebook 段

### 建议任务拆分
1. 定义 Lorebook / LorebookEntry 模型
2. 实现 LorebookParser
3. 实现 LorebookService(匹配 + 优先级 + constant)
4. 定义 Preset 模型与导入
5. 实现 PresetService
6. PromptBuilder 接入 Lorebook
7. 管理页 UI

---

## Phase 7:高级聊天功能

### 目标
实现回复重生成、回复切换(Swipe)、导入导出、主题切换。

### 输入
- SillyTavern public/scripts/swipe-picker.js、chats.js
- SillyTavern src/endpoints/characters.js、chats.js、backups.js

### 输出
- services/ChatService.regenerate / swipe
- models/MessageSwipe
- storage/ImportExportService(角色卡 / 聊天 / 全量)
- theme/ 与暗色资源
- 聊天页 Swipe 切换 UI

### 依赖
- Phase 6 完成

### 风险
- Swipe 与数据库 schema 变更(需迁移)
- 导出格式与 SillyTavern 兼容性
- 主题资源工作量

### 验收标准
- [ ] 可对最后一条回复重新生成
- [ ] 同一条用户消息可保存多个 AI 回复并切换
- [ ] 可导出角色卡 / 单聊 / 全量为 JSON
- [ ] 可导入此前导出的 JSON
- [ ] 明暗主题可切换

### 建议任务拆分
1. Message schema 增加 swipes 字段 + 数据库迁移
2. 实现 regenerate
3. 实现 swipe(新增 / 切换)
4. 实现 ImportExportService(角色卡)
5. 实现 ImportExportService(聊天 / 全量)
6. 主题与暗色资源
7. Swipe 切换 UI

---

## Phase 8:多 Provider 与多媒体能力

### 目标
扩展 Claude / Gemini / OpenRouter Provider,并探索 TTS / 图片生成 / 群聊(按需,个人使用优先级可降)。

### 输入
- SillyTavern src/endpoints/anthropic.js、google.js、openrouter.js
- SillyTavern src/endpoints/speech.js、images.js、stable-diffusion.js、groups.js

### 输出
- network/providers/ClaudeProvider、GeminiProvider、OpenRouterProvider
- services/TtsService(可选)
- services/ImageGenService(可选)
- services/GroupChatService(可选)

### 依赖
- Phase 7 完成

### 风险
- Claude/Gemini 的请求格式与 OpenAI 差异大
- TTS/图片生成的额外鉴权与计费
- 群聊调度复杂度高

### 验收标准
- [ ] Claude / Gemini / OpenRouter 至少一个可流式聊天
- [ ] (可选)TTS 可朗读回复
- [ ] (可选)图片生成可产出图片
- [ ] (可选)群聊可多角色轮询

### 建议任务拆分
1. Provider 接口抽象复用
2. ClaudeProvider(参考 anthropic.js)
3. GeminiProvider(参考 google.js)
4. OpenRouterProvider(参考 openrouter.js)
5. (可选)TtsService
6. (可选)ImageGenService
7. (可选)GroupChatService

---

## 2. 阶段依赖关系

```
Phase 0 (基线 + PoC)
   │
   ▼
Phase 1 (模型配置 + 接口连通)
   │
   ▼
Phase 2 (基础聊天,内存态)
   │
   ▼
Phase 3 (角色卡导入,内存态)
   │
   ▼
Phase 4 (本地数据库,持久化)
   │
   ▼
Phase 5 (Prompt + 宏)
   │
   ▼
Phase 6 (世界书 + 预设)
   │
   ▼
Phase 7 (高级聊天 + 导入导出 + 主题)
   │
   ▼
Phase 8 (多 Provider + 多媒体)
```

Phase 0 的两项 PoC(SSE、安全存储)是整个计划的技术基线,必须最先完成且独立可验证。

---

## 3. 全局验收里程碑

完成 Phase 1 后:可配置 API 并与 OpenAI 兼容端点流式对话(无角色、无持久化)。
完成 Phase 4 后:具备完整持久化的单角色聊天应用。
完成 Phase 6 后:达到 AGENTS.md 定义的"Final Objective"基础形态(导入角色卡、配置 API、流式聊天、世界书生效)。
完成 Phase 7 后:功能性接近 SillyTavern 常用能力。
Phase 8 为扩展能力,按个人使用优先级取舍。
