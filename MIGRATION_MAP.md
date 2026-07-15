# ArkTavern 迁移映射

Version: 0.1
Date: 2026-07-15

---

## 1. 目的

本文档将 ArkTavern 所需功能逐项映射到:
- MiniTavern 中的参考位置(功能/UX 层面)
- SillyTavern 中的参考位置(逻辑/数据格式层面)
- ArkTavern 的目标模块
- 实现方式(原生重写 / 适配 / 新建)
- 优先级(对应 DEVELOPMENT_PLAN.md 的阶段)

所有"实现方式"均为 ArkTS/ArkUI 原生实现,禁止直接复制参考源码。

---

## 2. 优先级说明

| 优先级 | 阶段 | 含义 |
|--------|------|------|
| P0 | Phase 0 | 工程基线 / 技术验证 |
| P1 | Phase 1 | 模型配置与接口连通 |
| P1 | Phase 2 | 基础聊天 |
| P1 | Phase 3 | 角色卡导入 |
| P1 | Phase 4 | 本地数据库 |
| P1 | Phase 5 | Prompt 与宏系统 |
| P2 | Phase 6 | 世界书与预设 |
| P2 | Phase 7 | 高级聊天功能 |
| P3 | Phase 8 | 多 Provider 与多媒体 |

---

## 3. 迁移映射表

| 功能 | MiniTavern 参考位置 | SillyTavern 参考位置 | ArkTavern 目标模块 | 实现方式 | 优先级 |
|------|---------------------|----------------------|---------------------|----------|--------|
| **模型配置**(Provider 选择 / Base URL / Model 名 / 温度等) | app.config(功能面) | public/scripts/openai.js、textgen-settings.js、kai-settings.js | models/ProviderConfig;services/ModelService;pages/ModelSettingsPage | 新建:ArkTS 数据模型 + ArkUI 表单 | P1 |
| **API Key 管理**(安全存储 / 多 Provider 密钥) | app.config(功能面) | src/endpoints/secrets.js、public/scripts/secrets.js | storage/KeyStore(基于 @ohos.security.huks) | 新建:HarmonyOS huks 加密存储,不参考 SillyTavern 实现 | P1 |
| **OpenAI-compatible 接口**(Chat Completions 请求) | index.android.bundle(功能面) | src/endpoints/backends/chat-completions.js、public/scripts/openai.js | network/providers/OpenAIProvider;network/core/HttpClient | 重写:参考请求体结构,ArkTS 用 @ohos.net.http 或 rcp 实现 | P1 |
| **流式输出**(SSE 增量解析) | index.android.bundle(功能面) | public/scripts/sse-stream.js、streaming-display.js | network/streaming/SseParser;viewmodels/ChatViewModel | 重写:参考 SSE 帧解析算法,ArkTS 实现增量回调 | P1(Phase 0 PoC) |
| **角色卡 JSON**(V2/V3 解析) | app.config(功能面) | src/character-card-parser.js、default/content/ | parser/character/CharacterCardParser;models/Character | 重写:参考 V2/V3 schema,ArkTS interface + JSON 解析 | P1(Phase 3) |
| **角色卡 PNG**(tEXt/iTXt chunk 提取) | index.android.bundle(功能面) | src/png/(PNG 元数据读写) | parser/png/PngMetadataReader | 重写:纯 ArkTS 实现 PNG chunk 扫描,不依赖 Node Buffer | P2(Phase 2+ PoC) |
| **角色列表**(列表 / 头像 / 搜索) | app.manifest 角色资源结构 | src/endpoints/characters.js、public/scripts/char-data.js | pages/CharacterListPage;components/CharacterCard;repositories/CharacterRepository | 新建:ArkUI LazyForEach + 数据库读取 | P1(Phase 4) |
| **单角色聊天**(消息流 / 发送 / 接收) | index.android.bundle(聊天页 UX) | src/endpoints/chats.js、public/scripts/chats.js | pages/ChatPage;viewmodels/ChatViewModel;services/ChatService | 新建:ArkUI List + 流式渲染 | P1(Phase 2) |
| **Prompt 构建**(System→Char→Scenario→Lorebook→Examples→History→Input→Post) | index.android.bundle(功能面) | public/scripts/openai.js、sysprompt.js、authors-note.js、instruct-mode.js | services/PromptBuilder | 重写:参考拼接顺序与规则,ArkTS 实现 | P1(Phase 5) |
| **宏替换**({{user}} / {{char}} / {{description}} 等) | index.android.bundle(功能面) | public/scripts/macros/(definitions/engine/macro-system.js) | services/MacroReplacer;models/Macro | 重写:参考宏定义清单与替换规则 | P1(Phase 5) |
| **世界书**(关键词匹配 / 优先级 / constant) | index.android.bundle(功能面) | public/scripts/world-info.js、src/endpoints/worldinfo.js | services/LorebookService;parser/lorebook/LorebookParser;models/Lorebook | 重写:参考匹配算法,ArkTS 实现 | P2(Phase 6) |
| **预设**(采样参数 / 系统提示模板) | app.config(功能面) | src/endpoints/presets.js、public/scripts/preset-manager.js | services/PresetService;models/Preset | 重写:参考预设 JSON 格式 | P2(Phase 6) |
| **聊天记录**(本地持久化 / 多会话) | index.android.bundle(功能面) | src/endpoints/chats.js、public/scripts/chats.js、chat-backups.js | services/ChatService;database/ChatRepository;models/Chat/Message | 新建:HarmonyOS RDB 存储 | P1(Phase 4) |
| **回复重生成**(Regenerate) | index.android.bundle(功能面) | public/scripts/openai.js(generate handler) | services/ChatService.regenerate | 新建:删除最后一条 assistant 消息后重新请求 | P2(Phase 7) |
| **回复切换**(Swipe) | index.android.bundle(功能面) | public/scripts/swipe-picker.js、chats.js(swipe 字段) | services/ChatService.swipe;models/MessageSwipe | 新建:Message 持有 swipes 数组 | P2(Phase 7) |
| **导入导出**(角色卡 / 聊天 / 全量) | app.config(功能面) | src/endpoints/characters.js、chats.js、backups.js;public/scripts/chat-backups.js | storage/ImportExportService | 重写:参考数据格式,HarmonyOS 文件选择器 + JSON 序列化 | P2(Phase 7) |
| **TTS**(文本转语音) | app.config(功能面) | src/endpoints/speech.js、public/scripts/(无独立文件) | services/TtsService(Phase 8) | 新建:HarmonyOS @ohos.textToSpeech 或 Provider TTS API | P3(Phase 8) |
| **图片生成** | app.config(功能面) | src/endpoints/images.js、stable-diffusion.js | services/ImageGenService(Phase 8) | 新建:参考 SD/Provider API | P3(Phase 8) |
| **群聊**(多角色轮询) | app.config(功能面) | src/endpoints/groups.js、public/scripts/group-chats.js | services/GroupChatService(Phase 8) | 新建:参考群聊调度逻辑 | P3(Phase 8) |

---

## 4. 补充映射(支撑性能力)

| 功能 | SillyTavern 参考位置 | ArkTavern 目标模块 | 实现方式 | 优先级 |
|------|----------------------|---------------------|----------|--------|
| Token 计数 | public/scripts/tokenizers.js、src/tokenizers/ | utils/TokenCounter | 简化实现:基于字符数估算,精确计数留待后续 | P2(Phase 5) |
| 日志系统 | src/util.js(logger) | utils/Logger | 新建:基于 hilog 封装,严禁打印 API Key | P0(Phase 0) |
| UUID 生成 | src/util.js | utils/Uuid | 新建:ArkTS 实现 | P0(Phase 0) |
| 时间工具 | src/util.js | utils/Time | 新建 | P0(Phase 0) |
| 错误处理 / 重试 | src/endpoints/backends/(fetch 重试) | network/core/RetryPolicy | 新建:指数退避,区分网络错误与 API 错误 | P1(Phase 1) |
| 超时控制 | src/(fetch timeout) | network/core/HttpClient | 新建:HarmonyOS http 配置 connectTimeout / readTimeout | P1(Phase 1) |
| 用户人格(Persona) | public/scripts/personas.js | models/Persona;services/PersonaService | 新建:参考字段 | P2(Phase 6) |
| 主题(明/暗) | src/endpoints/themes.js、public/scripts/power-user.js | theme/;resources/dark | 新建:HarmonyOS 资源限定 + setColorMode | P2(Phase 7) |
| 备份与恢复 | src/endpoints/backups.js | storage/BackupService(复用 EntryBackupAbility) | 新建:基于已有 BackupExtensionAbility 扩展 | P3(Phase 8) |

---

## 5. 实现方式分类汇总

### 5.1 参考格式 + ArkTS 重写(逻辑蓝本)

- 角色卡 JSON 解析(参考 character-card-parser.js)
- 世界书匹配(参考 world-info.js)
- 预设解析(参考 presets.js)
- Prompt 构建(参考 openai.js / sysprompt.js)
- 宏替换(参考 macros/*)
- OpenAI 请求构造(参考 chat-completions.js)
- SSE 解析(参考 sse-stream.js)
- PNG 元数据(参考 src/png/)

### 5.2 纯原生新建(HarmonyOS 能力)

- API Key 存储(huks / cryptoFramework)
- 偏好存储(@ohos.data.preferences)
- 数据库(@ohos.data.relationalStore)
- HTTP 客户端(@ohos.net.http 或 rcp)
- 文件选择与读写(@ohos.file.fs / picker)
- TTS(@ohos.textToSpeech)
- 日志(hilog)
- UI(ArkUI 原生组件)

### 5.3 仅 UX 参考(MiniTavern)

- 聊天页交互布局
- 角色列表展示
- 模型设置表单
- 背景图切换
- 引导页

---

## 6. 阶段交付与映射对齐

本映射表的优先级与 `DEVELOPMENT_PLAN.md` 的阶段一一对应,详细任务拆分见 `TODO.md`。每个阶段开始前应复核对应行项的参考文件是否仍然可用(参考目录只读,但不保证后续不更新版本)。
