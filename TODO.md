# ArkTavern 可执行任务清单

Version: 0.1
Date: 2026-07-15

---

## 1. 使用说明

- 每个任务可由 Agent 独立完成,修改范围明确,不跨过多模块。
- 依赖栏标注前置任务 ID;前置未完成不得开始。
- 优先级对应 DEVELOPMENT_PLAN.md 的阶段。
- 验收标准是任务完成的判定依据,必须逐条满足。
- 任务执行前应先阅读对应参考文件(SillyTavern 源码只读)。
- 编码遵循 AGENTS.md:无 any、明确定义 interface/class/enum、函数 ≤100 行、文件 ≤600 行、不打印 API Key。

---

## 2. 任务状态图例

- [ ] 未开始
- [x] 已完成
- [~] 进行中

---

## Phase 0:工程审计与基础架构

### T-0.1 创建基础工具模块(Logger / Uuid / Time)

- 依赖:无
- 优先级:P0
- 修改范围:`entry/src/main/ets/utils/`(新建)
- 参考文件:无(纯原生)
- 内容:
  - `utils/Logger.ets`:基于 hilog 的分级日志封装(debug/info/warn/error),提供 `redact()` 方法对敏感字段脱敏
  - `utils/Uuid.ets`:ArkTS UUID v4 生成
  - `utils/Time.ets`:时间戳与格式化工具
- 验收标准:
  - [ ] Logger 可分级输出且对 `apiKey`/`Authorization` 等关键字段脱敏
  - [ ] Uuid 生成符合 v4 格式
  - [ ] Time 可生成毫秒时间戳与 ISO 字符串
  - [ ] code-linter 无 error

### T-0.2 定义网络核心错误模型与 HttpClient 接口

- 依赖:无
- 优先级:P0
- 修改范围:`entry/src/main/ets/network/core/`(新建)
- 内容:
  - `models/NetworkError.ets`:定义 ApiError / TimeoutError / AuthError / ParseError 等枚举与类
  - `network/core/HttpClient.ets`:HTTP 客户端接口(请求/响应抽象,不绑定具体实现)
- 验收标准:
  - [ ] 错误类型可区分网络/超时/鉴权/解析
  - [ ] HttpClient 为 interface,无具体 SDK 耦合
  - [ ] 不含 any

### T-0.3 SSE 流式接收 PoC(关键技术验证)

- 依赖:T-0.1、T-0.2
- 优先级:P0
- 修改范围:`entry/src/main/ets/network/streaming/`(新建)+ 临时验证页
- 参考文件:`ArkTavern-Reference/SillyTavern-release/public/scripts/sse-stream.js`(只读,参考帧解析)
- 内容:
  - `network/streaming/SseParser.ets`:解析 SSE 帧(data: / event: / [DONE])
  - 临时 PoC:对接任意 OpenAI 兼容端点(需用户提供测试 Base URL + Key),增量打印 token
  - 确认 `@ohos.net.http` 的 `on('dataReceive')` 可用性;若不可用则验证 `rcp` 方案
- 验收标准:
  - [ ] SseParser 能正确解析多帧 SSE 数据
  - [ ] PoC 能对接真实端点并增量输出
  - [ ] 中断(abort)可正常工作
  - [ ] 输出 PoC 结论:最终采用 http 还是 rcp

### T-0.4 安全存储 PoC(huks 加密 API Key)

- 依赖:T-0.1
- 优先级:P0
- 修改范围:`entry/src/main/ets/storage/`(新建)+ 临时验证
- 内容:
  - `storage/KeyStore.ets`:基于 `@ohos.security.huks` 的加密存储 PoC(AES-GCM)
  - 验证 huks 在 API 23 对 AES-GCM 的支持
  - 确认 code-linter 安全规则通过(不得使用 ECB/MD5/SHA1/3DES)
- 验收标准:
  - [ ] 可加密保存一段文本并解密还原
  - [ ] 算法模式为 AES-GCM(或同等合规)
  - [ ] code-linter 无 error
  - [ ] 输出 PoC 结论:huks 是否满足 KeyStore 需求

### T-0.5 确立分层目录与导出约定

- 依赖:T-0.1 ~ T-0.4
- 优先级:P0
- 修改范围:仅约定,不创建空目录
- 内容:在 AGENTS.md / ARCHITECTURE.md 基础上,确认实际目录与模块导出方式(Barrel export 或直接路径),记录到后续任务
- 验收标准:
  - [ ] 明确每个新文件的归属目录
  - [ ] 不存在空目录或占位文件

---

## Phase 1:模型配置与接口连通

### T-1.1 定义 Provider 与消息数据模型

- 依赖:T-0.5
- 优先级:P1
- 修改范围:`entry/src/main/ets/models/`(新建)
- 参考文件:`SillyTavern-release/public/scripts/openai.js`(只读,参考字段)
- 内容:
  - `models/ProviderType.ets`(枚举:OpenAICompatible / DeepSeek / OpenRouter / Claude / Gemini)
  - `models/ProviderConfig.ets`(id / name / type / baseUrl / modelName / 温度等)
  - `models/ChatRole.ets`(System / User / Assistant)
  - `models/ChatMessage.ets`(role / content / created)
  - `models/ChatRequest.ets`(model / messages / temperature / stream 等)
- 验收标准:
  - [ ] 所有模型为 interface 或 class,无 any
  - [ ] 字段覆盖 OpenAI Chat Completions 常用参数

### T-1.2 实现多密钥 KeyStore

- 依赖:T-0.4、T-1.1
- 优先级:P1
- 修改范围:`entry/src/main/ets/storage/KeyStore.ets`(扩展)
- 内容:支持按 Provider id 存取多个密钥;密钥不入数据库、不入日志
- 验收标准:
  - [ ] 可按 id 加密保存/读取/删除密钥
  - [ ] 失败时返回明确错误,不抛明文

### T-1.3 实现 Preferences(用户设置)

- 依赖:T-0.5
- 优先级:P1
- 修改范围:`entry/src/main/ets/storage/Preferences.ets`(新建)
- 内容:基于 `@ohos.data.preferences` 存储当前选中 Provider id、当前角色、当前聊天等非敏感设置
- 验收标准:
  - [ ] 可读写非敏感设置
  - [ ] 无明文密钥

### T-1.4 实现 OpenAIProvider(非流式)

- 依赖:T-0.2、T-1.1、T-1.2
- 优先级:P1
- 修改范围:`entry/src/main/ets/network/providers/`(新建)
- 参考文件:`SillyTavern-release/src/endpoints/backends/chat-completions.js`(只读)
- 内容:`network/providers/OpenAIProvider.ets`,实现 POST `/v1/chat/completions`,Authorization: Bearer
- 验收标准:
  - [ ] 可发送非流式请求并解析 choices
  - [ ] 鉴权失败返回 AuthError

### T-1.5 实现 OpenAIProvider(流式)

- 依赖:T-0.3、T-1.4
- 优先级:P1
- 修改范围:`network/providers/OpenAIProvider.ets`(扩展)
- 内容:stream=true,复用 SseParser,通过回调增量返回 delta
- 验收标准:
  - [ ] 可增量返回 token
  - [ ] 可中断
  - [ ] [DONE] 正确结束

### T-1.6 实现 ModelService

- 依赖:T-1.2、T-1.3、T-1.5
- 优先级:P1
- 修改范围:`entry/src/main/ets/services/`(新建)
- 内容:`services/ModelService.ets`:Provider 配置 CRUD、当前选中 Provider、发送聊天请求(流式/非流式)
- 验收标准:
  - [ ] 页面层不直接接触网络层
  - [ ] 可切换 Provider

### T-1.7 实现模型设置页与最小验证页

- 依赖:T-1.6
- 优先级:P1
- 修改范围:`entry/src/main/ets/pages/`、`entry/src/main/ets/viewmodels/`、`main_pages.json`
- 内容:`pages/ModelSettingsPage.ets`(表单)、`pages/QuickChatPage.ets`(输入一句话 → 流式显示回复)、对应 ViewModel
- 验收标准:
  - [ ] 可保存多个 Provider 配置
  - [ ] 可发送一句话并看到流式回复
  - [ ] 错误有提示

### T-1.8 补充网络权限

- 依赖:T-1.7
- 优先级:P1
- 修改范围:`entry/src/main/module.json5`(requestPermissions)
- 内容:声明 `ohos.permission.INTERNET`;若需明文 HTTP(本地模型)补充 networkConfig
- 验收标准:
  - [ ] HTTPS 默认可用
  - [ ] 真机可联通外网端点

---

## Phase 2:基础聊天

### T-2.1 定义内存态聊天视图模型

- 依赖:T-1.6
- 优先级:P1
- 修改范围:`entry/src/main/ets/viewmodels/`
- 内容:`viewmodels/ChatViewModel.ets`:消息列表状态、输入态、流式态、错误态
- 验收标准:
  - [ ] 状态可观察(@State / @Observed)
  - [ ] 无网络层直接调用

### T-2.2 实现 ChatService(内存态)

- 依赖:T-1.6、T-2.1
- 优先级:P1
- 修改范围:`entry/src/main/ets/services/ChatService.ets`(新建)
- 内容:发送消息 → 调用 ModelService → 增量更新 ViewModel;支持中断
- 验收标准:
  - [ ] 可发送并接收流式回复
  - [ ] 可中断生成

### T-2.3 实现消息气泡组件

- 依赖:T-2.1
- 优先级:P1
- 修改范围:`entry/src/main/ets/components/`(新建)
- 内容:`components/MessageBubble.ets`:用户/助手区分、Markdown 简化渲染(粗体/斜体/代码块)
- 验收标准:
  - [ ] 用户与助手气泡视觉区分
  - [ ] 代码块等基础格式可读

### T-2.4 实现输入区组件

- 依赖:T-2.1
- 优先级:P1
- 修改范围:`entry/src/main/ets/components/ChatInput.ets`
- 内容:多行输入、发送、停止按钮、空输入禁用发送
- 验收标准:
  - [ ] 可输入并发送
  - [ ] 生成中按钮切换为"停止"

### T-2.5 实现 ChatPage 与流式渲染

- 依赖:T-2.2、T-2.3、T-2.4
- 优先级:P1
- 修改范围:`entry/src/main/ets/pages/ChatPage.ets`、`main_pages.json`
- 内容:消息列表(LazyForEach)+ 输入区 + 流式指示器;新消息自动滚到底部
- 验收标准:
  - [ ] 流式渲染不卡顿
  - [ ] 长列表性能可接受
  - [ ] 生成中可滚动查看历史

---

## Phase 3:角色卡导入

### T-3.1 定义 Character 内部模型

- 依赖:T-0.5
- 优先级:P1
- 修改范围:`entry/src/main/ets/models/Character.ets`
- 参考文件:`SillyTavern-release/src/character-card-parser.js`、`default/content/` 样例
- 内容:V2/V3 字段映射到内部 interface(name / description / personality / scenario / firstMes / mesExample / alternateGreetings / creator / spec / 等)
- 验收标准:
  - [ ] 可承载 V2 与 V3 字段
  - [ ] 缺失字段有默认值

### T-3.2 实现 CharacterCardParser

- 依赖:T-3.1
- 优先级:P1
- 修改范围:`entry/src/main/ets/parser/character/`(新建)
- 内容:`CharacterCardParser.ets`:解析 JSON,识别 V2(`spec=chara_card_v2`)/V3,校验必填字段
- 验收标准:
  - [ ] 可解析 V2/V3 样例
  - [ ] 非法 JSON 返回明确错误

### T-3.3 实现文件选择与导入

- 依赖:T-3.2
- 优先级:P1
- 修改范围:`entry/src/main/ets/services/CharacterService.ets`、`parser/character/`
- 内容:使用 `@ohos.file.picker` 选择 JSON,读取并解析
- 验收标准:
  - [ ] 可从文件系统选择并导入
  - [ ] 导入失败有提示

### T-3.4 实现 CharacterService(内存态)

- 依赖:T-3.3
- 优先级:P1
- 修改范围:`services/CharacterService.ets`
- 内容:导入 / 列表 / 选中当前角色
- 验收标准:
  - [ ] 可管理多个角色
  - [ ] 可切换当前角色

### T-3.5 实现角色列表页与导入页

- 依赖:T-3.4
- 优先级:P1
- 修改范围:`pages/CharacterListPage.ets`、`pages/CharacterImportPage.ets`、`main_pages.json`
- 验收标准:
  - [ ] 列表展示已导入角色
  - [ ] 可触发导入流程

### T-3.6 聊天页接入角色上下文

- 依赖:T-2.5、T-3.4
- 优先级:P1
- 修改范围:`services/ChatService.ets`、`pages/ChatPage.ets`
- 内容:选中角色后,首条消息使用 firstMes,描述/人设/场景拼入临时 Prompt
- 验收标准:
  - [ ] 角色首条消息正确显示
  - [ ] 角色描述进入请求上下文

---

## Phase 4:本地数据库

### T-4.1 设计建表脚本

- 依赖:T-0.5
- 优先级:P1
- 修改范围:`entry/src/main/ets/database/`(新建)
- 参考文件:ARCHITECTURE.md 表结构
- 内容:`database/schema.ets`:characters / chats / messages 建表 SQL
- 验收标准:
  - [ ] 字段与 ARCHITECTURE.md 一致
  - [ ] 含必要索引

### T-4.2 实现 DbHelper

- 依赖:T-4.1
- 优先级:P1
- 修改范围:`database/DbHelper.ets`
- 内容:基于 `@ohos.data.relationalStore` 初始化、版本管理
- 验收标准:
  - [ ] 可创建并打开库
  - [ ] 重复执行不报错

### T-4.3 实现 CharacterRepository

- 依赖:T-4.2、T-3.1
- 优先级:P1
- 修改范围:`entry/src/main/ets/repositories/`(新建)
- 验收标准:
  - [ ] CRUD 可用
  - [ ] 不含 UI 逻辑

### T-4.4 实现 ChatRepository / MessageRepository

- 依赖:T-4.2
- 优先级:P1
- 修改范围:`repositories/`
- 验收标准:
  - [ ] 可按 chatId 分页查询消息
  - [ ] 增删改落库

### T-4.5 Service 层切换为 Repository

- 依赖:T-4.3、T-4.4、T-2.2、T-3.4
- 优先级:P1
- 修改范围:`services/ChatService.ets`、`services/CharacterService.ets`
- 验收标准:
  - [ ] 重启后数据保留
  - [ ] 多会话切换正常

---

## Phase 5:Prompt 与宏系统

### T-5.1 定义 PromptSegment 模型与顺序

- 依赖:T-0.5
- 优先级:P1
- 修改范围:`models/PromptSegment.ets`
- 参考文件:AGENTS.md Prompt 顺序
- 验收标准:
  - [ ] 顺序枚举完整

### T-5.2 实现 MacroReplacer(标准宏)

- 依赖:T-3.1
- 优先级:P1
- 修改范围:`services/MacroReplacer.ets`
- 参考文件:`SillyTavern-release/public/scripts/macros/*`
- 内容:{{user}} / {{char}} / {{description}} / {{scenario}} / {{personality}} / {{lastMessage}}
- 验收标准:
  - [ ] 所有标准宏可替换
  - [ ] 未识别宏保留原样

### T-5.3 实现 PromptBuilder

- 依赖:T-5.1、T-5.2
- 优先级:P1
- 修改范围:`services/PromptBuilder.ets`
- 参考文件:`SillyTavern-release/public/scripts/openai.js`、`sysprompt.js`
- 验收标准:
  - [ ] 顺序符合 AGENTS.md
  - [ ] 各段可空跳过

### T-5.4 实现简化 TokenCounter

- 依赖:T-5.3
- 优先级:P1
- 修改范围:`utils/TokenCounter.ets`
- 验收标准:
  - [ ] 给出近似 token 数

### T-5.5 历史消息窗口截断

- 依赖:T-5.3、T-5.4、T-4.4
- 优先级:P1
- 修改范围:`services/PromptBuilder.ets`
- 验收标准:
  - [ ] 超限历史可截断

### T-5.6 ChatService 接入 PromptBuilder

- 依赖:T-5.5、T-2.2
- 优先级:P1
- 修改范围:`services/ChatService.ets`
- 验收标准:
  - [ ] 端到端 Prompt 正确

---

## Phase 6:世界书与预设

### T-6.1 定义 Lorebook 模型

- 依赖:T-0.5
- 优先级:P2
- 修改范围:`models/Lorebook.ets`
- 参考文件:`SillyTavern-release/public/scripts/world-info.js`
- 验收标准:
  - [ ] 含 keys / content / priority / constant / enabled 字段

### T-6.2 实现 LorebookParser

- 依赖:T-6.1
- 优先级:P2
- 修改范围:`parser/lorebook/`(新建)
- 验收标准:
  - [ ] 可解析样例 JSON

### T-6.3 实现 LorebookService(匹配 + 优先级 + constant)

- 依赖:T-6.2、T-4.3
- 优先级:P2
- 修改范围:`services/LorebookService.ets`
- 验收标准:
  - [ ] constant 始终注入
  - [ ] 关键词命中按优先级注入

### T-6.4 定义 Preset 模型与导入

- 依赖:T-0.5
- 优先级:P2
- 修改范围:`models/Preset.ets`、`services/PresetService.ets`
- 参考文件:`SillyTavern-release/src/endpoints/presets.js`
- 验收标准:
  - [ ] 可导入预设

### T-6.5 PromptBuilder 接入 Lorebook

- 依赖:T-5.3、T-6.3
- 优先级:P2
- 修改范围:`services/PromptBuilder.ets`
- 验收标准:
  - [ ] Lorebook 段出现在正确位置

### T-6.6 世界书与预设管理页

- 依赖:T-6.3、T-6.4
- 优先级:P2
- 修改范围:`pages/`、`main_pages.json`
- 验收标准:
  - [ ] 可管理世界书与预设

---

## Phase 7:高级聊天功能

### T-7.1 Message schema 增加 swipes + 数据库迁移

- 依赖:T-4.4
- 优先级:P2
- 修改范围:`database/`、`models/`
- 验收标准:
  - [ ] 迁移可重复执行

### T-7.2 实现 regenerate

- 依赖:T-7.1、T-5.6
- 优先级:P2
- 修改范围:`services/ChatService.ets`
- 验收标准:
  - [ ] 可重新生成最后一条回复

### T-7.3 实现 swipe(新增/切换)

- 依赖:T-7.1
- 优先级:P2
- 修改范围:`services/ChatService.ets`
- 验收标准:
  - [ ] 同一用户消息可多回复切换

### T-7.4 实现 ImportExportService(角色卡)

- 依赖:T-4.3
- 优先级:P2
- 修改范围:`storage/ImportExportService.ets`
- 验收标准:
  - [ ] 可导出/导入角色卡 JSON

### T-7.5 实现 ImportExportService(聊天/全量)

- 依赖:T-7.4、T-4.4
- 优先级:P2
- 修改范围:`storage/ImportExportService.ets`
- 验收标准:
  - [ ] 可导出/导入单聊与全量

### T-7.6 主题与暗色资源

- 依赖:T-0.5
- 优先级:P2
- 修改范围:`theme/`、`resources/dark/`
- 验收标准:
  - [ ] 明暗可切换

### T-7.7 Swipe 切换 UI

- 依赖:T-7.3、T-2.3
- 优先级:P2
- 修改范围:`components/`
- 验收标准:
  - [ ] 可左右切换回复

---

## Phase 8:多 Provider 与多媒体

### T-8.1 抽象 Provider 接口

- 依赖:T-1.6
- 优先级:P3
- 修改范围:`network/providers/`
- 验收标准:
  - [ ] OpenAIProvider 符合新接口

### T-8.2 实现 ClaudeProvider

- 依赖:T-8.1
- 优先级:P3
- 修改范围:`network/providers/ClaudeProvider.ets`
- 参考文件:`SillyTavern-release/src/endpoints/anthropic.js`
- 验收标准:
  - [ ] 可流式聊天

### T-8.3 实现 GeminiProvider

- 依赖:T-8.1
- 优先级:P3
- 修改范围:`network/providers/GeminiProvider.ets`
- 参考文件:`SillyTavern-release/src/endpoints/google.js`
- 验收标准:
  - [ ] 可流式聊天

### T-8.4 实现 OpenRouterProvider

- 依赖:T-8.1
- 优先级:P3
- 修改范围:`network/providers/OpenRouterProvider.ets`
- 参考文件:`SillyTavern-release/src/endpoints/openrouter.js`
- 验收标准:
  - [ ] 可流式聊天

### T-8.5 (可选)TtsService

- 依赖:T-1.6
- 优先级:P3
- 修改范围:`services/TtsService.ets`
- 验收标准:
  - [ ] 可朗读回复

### T-8.6 (可选)ImageGenService

- 依赖:T-1.6
- 优先级:P3
- 修改范围:`services/ImageGenService.ets`
- 参考文件:`SillyTavern-release/src/endpoints/images.js`
- 验收标准:
  - [ ] 可生成图片

### T-8.7 (可选)GroupChatService

- 依赖:T-5.6
- 优先级:P3
- 修改范围:`services/GroupChatService.ets`
- 参考文件:`SillyTavern-release/src/endpoints/groups.js`、`public/scripts/group-chats.js`
- 验收标准:
  - [ ] 多角色可轮询

---

## 3. 推荐执行顺序

T-0.1 → T-0.2 → (T-0.3 ‖ T-0.4) → T-0.5 → T-1.1 → T-1.2 → T-1.3 → T-1.4 → T-1.5 → T-1.6 → T-1.7 → T-1.8 → T-2.x → T-3.x → T-4.x → T-5.x → T-6.x → T-7.x → T-8.x

第一项建议从 **T-0.3(SSE 流式接收 PoC)** 或 **T-0.1(基础工具)** 启动,二者无强依赖,可并行。SSE PoC 是整个聊天链路的最高风险点,应优先验证。
