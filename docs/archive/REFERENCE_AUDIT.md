# ArkTavern 参考资料审计报告

Version: 0.1
Date: 2026-07-15
Auditor: AI Agent

---

## 1. 审计范围

本报告审计 `D:\DevEco_studio\ArkTavern-Reference` 目录,识别可作为 ArkTavern 开发参考的资料,并明确划分"可参考"与"禁止复制"的边界。参考目录只读,任何修改、删除、重命名均被禁止。

---

## 2. 参考目录顶层结构

```
ArkTavern-Reference/
├── MiniTavern/                  # MiniTavern APK 解压内容(React Native / Expo 应用)
└── SillyTavern-release/         # SillyTavern 官方开源仓库全量源码(Node.js)
```

无 `Docs/` 目录(AGENTS.md 提及的 Docs 当前不存在,后续可按需生成分析文档,但本次不创建)。

---

## 3. MiniTavern 审计

### 3.1 性质判定

MiniTavern 是一个 **React Native + Expo** 构建的 Android 应用 APK 解压产物。判定依据:

- `assets/index.android.bundle` 存在(8,845,828 字节,即约 8.8MB 的打包 JS bundle)
- `assets/app.manifest` 含 `expo-router`、`@react-navigation/elements`、`@expo/vector-icons` 等 Expo/RN 依赖资源
- 存在 6 个 `classes.dex`(Kotlin/Java 编译产物,合计约 47MB)
- 大量 `play-services-*.properties`、`firebase-*.properties`、`billing*.properties`(Google 服务、Firebase、Google Play Billing)

### 3.2 顶层文件清单

| 文件/目录 | 类型 | 用途 | 可否参考 |
|-----------|------|------|----------|
| AndroidManifest.xml | 二进制 AXML | 应用权限与组件声明 | 仅功能清单参考(需反编译) |
| app.manifest | JSON | Expo 资源清单(bundle 元数据) | 仅功能清单参考 |
| app.config | 配置 | Expo 应用配置 | 仅功能清单参考 |
| assets/index.android.bundle | minified JS | RN 打包业务代码 | 禁止复制;仅作功能/交互分析材料 |
| classes.dex ~ classes6.dex | DEX | Kotlin/Java 字节码 | 禁止复制;禁止反编译提取源码 |
| res/ | Android 资源 | 图标/布局/字符串 | 仅 UI 风格参考 |
| kotlin/、lib/、okhttp3/、org/、google/ | 运行时库 | 第三方 SDK 字节码 | 禁止参考 |
| *.properties | 配置 | Google/Firebase/Billing 版本声明 | 不参考 |
| resources.arsc | 二进制 | Android 编译资源表 | 不参考 |
| META-INF/ | 签名 | APK 签名块 | 禁止提取/使用 |

### 3.3 assets 目录可用参考

```
assets/
├── com/appsflyer/internal/   # AppsFlyer SDK 内部资源(不参考)
├── dexopt/                   # DEX 优化目录(不参考)
├── app.config                # Expo 配置(功能清单参考)
├── dic                       # 字典文件(疑似分词/输入,不参考)
├── expo-root.pem             # Expo 根证书(不参考)
└── index.android.bundle      # RN 业务 bundle(只作功能分析,禁止复制)
```

### 3.4 从 app.manifest 可识别的功能清单

通过资源清单可间接识别 MiniTavern 的功能面(仅作功能发现,非代码参考):

- 内置背景图:`01.classroom` ~ `08.vista`(教室/咖啡店/图书馆/公园/办公室/卧室/赛博/远景)
- 角色占位图:`default-character`、`default-character-card`、`default-user`、`default-vip-user`、`noimage`
- 内置角色头像:`female` ~ `female6`、`male` ~ `male6`(12 个预设头像)
- 引导图:`guide_finger_1/2`、`welcome_banner`、`home_empty_premium/non_premium`
- 登录:`google_icon`、`bg_login`(Google 登录 + 登录页背景)
- 付费:`premium_bg`、`default-vip-user`(VIP/订阅体系)
- 广告:`assets/images/ads/char_01` ~ `char_07`(广告位角色图)
- 图标库:AntDesign / Entypo / Feather / FontAwesome / Ionicons / MaterialCommunityIcons 等(可参考图标风格)

### 3.5 MiniTavern 使用边界(强制)

允许:
- 识别功能清单(聊天、角色、背景、付费、登录、广告等)
- 研究页面结构与交互流程(通过反编译资源,不通过复制代码)
- 研究角色卡导入/导出方式(功能层面)
- 研究模型配置项(功能层面)

禁止:
- 将 APK 直接转换为 HarmonyOS 应用
- 复制 Android DEX 代码
- 复制 Kotlin / Java 源码
- 复制 index.android.bundle 或其中片段到 ArkTavern
- 绕过登录、订阅、支付、广告或授权限制
- 提取或使用开发者私有密钥
- 修改或重新分发 MiniTavern APK
- 复制闭源私有源码

---

## 4. SillyTavern 审计

### 4.1 性质判定

SillyTavern-release 是 SillyTavern 官方开源仓库的全量快照,Node.js + Express 服务端 + 浏览器前端架构。它是 ArkTavern 的**主要逻辑参考**,允许参考数据格式与业务逻辑,但禁止直接移植 Node.js / 浏览器代码。

### 4.2 顶层结构

```
SillyTavern-release/
├── src/                 # 服务端(Node.js / Express)
├── public/              # 浏览器前端(纯 JS)
├── default/             # 默认内容(角色卡/预设/配置模板)
├── data/                # 运行时数据(不参考)
├── backups/             # 备份(不参考)
├── plugins/             # 服务端插件(不参考)
├── docker/、colab/      # 部署脚本(不参考)
├── tests/               # 测试(可参考数据样例)
├── server.js            # 入口(不移植)
├── package.json         # 依赖声明(版本参考)
└── *.bat / *.sh         # 启动脚本(不参考)
```

### 4.3 src/ 服务端关键参考

#### 4.3.1 src 顶层

| 文件 | 用途 | ArkTavern 复用方式 |
|------|------|-------------------|
| character-card-parser.js | 角色卡 V2/V3 解析 | 参考 JSON schema,ArkTS 重写 |
| prompt-converters.js | Prompt 格式转换 | 参考转换逻辑,ArkTS 重写 |
| util.js | 通用工具 | 选择性参考 |
| constants.js | 常量 | 参考 |
| validators/ | 数据校验 | 参考 schema |
| png/ | PNG 元数据读写 | 参考 chunk 解析逻辑,ArkTS 重写(关键) |
| tokenizers/ | Token 计数 | 参考(可能不实现精确计数) |
| endpoints/ | API 端点 | 见下 |
| electron/、middleware/、git/、vectors/ | 服务端专属 | 不参考 |

#### 4.3.2 src/endpoints/

| 文件 | 参考价值 | ArkTavern 对应模块 |
|------|----------|-------------------|
| characters.js | 角色卡 CRUD、导入导出 | services/CharacterService |
| chats.js | 聊天记录读写 | services/ChatService |
| worldinfo.js | 世界书 | services/LorebookService |
| presets.js | 预设 | services/PresetService |
| secrets.js | API Key 管理(参考存储方式,非实现) | storage/KeyStore |
| settings.js | 用户设置 | storage/Preferences |
| avatars.js | 头像 | storage/文件 |
| thumbnails.js | 缩略图 | storage/文件 |
| themes.js | 主题 | theme/ |
| groups.js | 群聊 | services/GroupChatService(Phase 8) |
| images.js / stable-diffusion.js | 图片生成 | Phase 8 |
| speech.js | TTS | Phase 8 |
| tokenizers.js | Token 计数 | utils/TokenCounter |
| image-metadata.js | 图片元数据 | parser/png |

#### 4.3.3 src/endpoints/backends/(Provider 适配器核心参考)

| 文件 | 覆盖 Provider | ArkTavern 对应 |
|------|---------------|----------------|
| chat-completions.js | OpenAI Compatible / OpenAI / DeepSeek / OpenRouter / 通用 Chat Completions | network/providers/OpenAIProvider |
| text-completions.js | KoboldAI / TextGen WebUI / 传统补全 | 暂不实现(Phase 8+ 视情况) |
| anthropic.js (endpoints 顶层) | Claude | network/providers/ClaudeProvider(Phase 8) |
| google.js (endpoints 顶层) | Gemini | network/providers/GeminiProvider(Phase 8) |
| openrouter.js (endpoints 顶层) | OpenRouter | network/providers/OpenRouterProvider |
| novelai.js / minimax.js / volcengine.js / horde.js / nanogpt.js / azure.js | 其他 | 暂不实现 |

### 4.4 public/scripts/ 前端关键参考

SillyTavern 的核心业务逻辑大量位于浏览器前端 JS,这些是 ArkTavern 重写的**主要逻辑蓝本**:

| 文件 | 参考价值 | ArkTavern 对应 |
|------|----------|----------------|
| openai.js | Chat Completions 请求构造、消息拼接、流式处理 | services/PromptBuilder + network/providers |
| world-info.js | 世界书匹配、关键词扫描、优先级、constant | services/LorebookService + parser/lorebook |
| macros.js | 宏替换入口 | services/MacroReplacer |
| macros/definitions/ | 宏定义清单 | models/Macro |
| macros/engine/ | 宏引擎实现 | services/MacroReplacer |
| macros/macro-system.js | 宏系统总入口 | services/MacroReplacer |
| sysprompt.js | 系统提示组装 | services/PromptBuilder |
| authors-note.js | 作者注 | services/PromptBuilder |
| instruct-mode.js | 指令模式 | services/PromptBuilder |
| preset-manager.js | 预设管理 | services/PresetService |
| chats.js | 聊天记录管理 | services/ChatService |
| chat-backups.js | 聊天备份 | storage/ImportExport |
| group-chats.js | 群聊 | Phase 8 |
| personas.js | 用户人格 | models/Persona |
| secrets.js | 前端密钥管理(仅参考交互) | storage/KeyStore |
| sse-stream.js | SSE 流式解析(前端) | network/streaming/SseParser(关键参考) |
| streaming-display.js | 流式渲染展示 | viewmodels/ChatViewModel |
| swipe-picker.js | 回复切换(Swipe) | services/ChatService |
| tokenizers.js | Token 计数 | utils/TokenCounter |
| power-user.js | 高级设置 | settings 页面参考 |
| textgen-settings.js / kai-settings.js / nai-settings.js | 各后端设置 | Provider 配置参考 |
| char-data.js | 角色数据字段 | models/Character |
| filters.js | 消息过滤 | utils |
| tags.js | 标签 | models/Tag(可选) |
| util/AccountStorage.js | 账号存储 | 不参考(服务端专属) |
| util/SimpleMutex.js | 互斥锁 | utils(可参考) |

### 4.5 default/ 默认内容参考

```
default/
├── content/          # 默认角色卡 / 预设 / 世界书样例(数据格式参考)
├── scaffold/         # 脚手架
├── config.yaml       # 默认配置(参考配置项清单)
└── !DO-NOT-EDIT-THESE-FILES.txt
```

`default/content/` 中的 JSON 文件是角色卡 V2/V3、预设、世界书的**真实数据样例**,可作为 parser 层的测试夹具与 schema 参考来源。

### 4.6 SillyTavern 使用边界(强制)

允许参考:
- 角色卡 V2/V3 数据格式(JSON schema)
- 世界书格式
- 预设格式
- 聊天记录格式
- Prompt 拼接逻辑
- 宏替换逻辑
- OpenAI-compatible 请求格式
- Provider 设计思路
- 流式输出解析逻辑(SSE 帧解析)
- 数据导入导出规则

禁止直接移植:
- Node.js 服务端代码(Express 路由、文件系统)
- 浏览器 DOM 操作代码
- WebView 页面
- 前端插件运行时
- Node.js Buffer / fs / path 等 API 用法

---

## 5. 参考资料用途总览

| 资料类别 | 来源 | 用途 | 边界 |
|----------|------|------|------|
| 角色卡 V2/V3 schema | SillyTavern default/content + src/character-card-parser.js | 定义 models/Character | 仅参考格式,ArkTS 重写解析器 |
| 世界书格式 | SillyTavern src/endpoints/worldinfo.js + public/scripts/world-info.js | 定义 models/Lorebook + 匹配逻辑 | 仅参考格式与算法,ArkTS 重写 |
| 预设格式 | SillyTavern src/endpoints/presets.js + default/content | 定义 models/Preset | 仅参考格式 |
| 聊天记录格式 | SillyTavern src/endpoints/chats.js + public/scripts/chats.js | 定义 models/Chat / Message | 仅参考格式 |
| Prompt 拼接 | SillyTavern public/scripts/openai.js + sysprompt.js + authors-note.js | services/PromptBuilder | 仅参考顺序与规则,ArkTS 重写 |
| 宏替换 | SillyTavern public/scripts/macros/* | services/MacroReplacer | 仅参考宏定义与替换规则 |
| OpenAI 请求构造 | SillyTavern src/endpoints/backends/chat-completions.js | network/providers/OpenAIProvider | 仅参考请求体结构,ArkTS 重写 |
| SSE 解析 | SillyTavern public/scripts/sse-stream.js | network/streaming/SseParser | 仅参考帧解析算法,ArkTS 重写 |
| PNG 元数据 | SillyTavern src/png/* | parser/png | 仅参考 chunk 解析,纯 ArkTS 重写 |
| 功能清单 | MiniTavern app.manifest + 资源 | 页面/功能发现 | 仅参考功能面,不复制代码 |
| 交互流程 | MiniTavern 资源结构 | UX 参考 | 仅参考流程,ArkUI 重写 |
| 图标风格 | MiniTavern 内置图标库(FontAwesome 等) | 图标选型 | 使用 HarmonyOS 系统图标或同等开源图标,不复制字体文件 |

---

## 6. 禁止直接复制清单(汇总)

1. MiniTavern 的 `index.android.bundle`(全部或片段)
2. MiniTavern 的 `classes*.dex`(全部)
3. MiniTavern 的 `AndroidManifest.xml`(二进制 AXML)
4. MiniTavern 的 `META-INF/` 签名块
5. MiniTavern 的 `kotlin/`、`lib/`、`okhttp3/`、`org/`、`google/` 运行时库
6. SillyTavern 的 `server.js`、Express 路由、Node.js `fs`/`path` 代码
7. SillyTavern 的浏览器 DOM 操作代码
8. SillyTavern 的 `electron/`、`docker/`、`colab/`、`plugins/` 部署/插件代码
9. 任何第三方字体文件(若需图标,使用 HarmonyOS 系统资源或合规开源图标)

---

## 7. 适合重新实现清单(汇总)

1. 角色卡 JSON 解析器(parser/character/)— 参考 SillyTavern schema
2. PNG 元数据解析器(parser/png/)— 参考 SillyTavern src/png/ 的 chunk 处理逻辑
3. 世界书解析与匹配(parser/lorebook/ + services/LorebookService)— 参考 SillyTavern world-info.js
4. 预设解析(parser/ + services/PresetService)— 参考 SillyTavern presets.js
5. Prompt 构建器(services/PromptBuilder)— 参考 SillyTavern openai.js / sysprompt.js
6. 宏替换器(services/MacroReplacer)— 参考 SillyTavern macros/*
7. OpenAI Compatible Provider(network/providers/)— 参考 SillyTavern chat-completions.js
8. SSE 流式解析器(network/streaming/)— 参考 SillyTavern sse-stream.js
9. 安全密钥存储(storage/KeyStore)— 使用 HarmonyOS huks/cryptoFramework,不参考 SillyTavern 实现
10. 偏好存储(storage/Preferences)— 使用 HarmonyOS @ohos.data.preferences
11. 数据库(database/)— 使用 HarmonyOS @ohos.data.relationalStore
12. 聊天 UI(pages/ + components/)— ArkUI 原生重写,MiniTavern 仅作 UX 参考

---

## 8. 审计结论

- 参考资料完备:MiniTavern 提供功能面与 UX 参考,SillyTavern 提供完整的数据格式与业务逻辑蓝本,足以支撑 ArkTavern 全部阶段开发。
- 关键参考已定位:`src/endpoints/backends/chat-completions.js`(Provider)、`public/scripts/sse-stream.js`(流式)、`public/scripts/macros/*`(宏)、`public/scripts/world-info.js`(世界书)、`src/character-card-parser.js`(角色卡)、`default/content/`(数据样例)。
- 边界清晰:APK 字节码与 RN bundle、Node.js 服务端代码、浏览器 DOM 代码均禁止移植,所有逻辑用 ArkTS 重写。
- 建议在 Phase 0 额外抽取 `default/content/` 中的若干角色卡/预设/世界书 JSON 作为 parser 层的测试夹具(只读引用,不进入工程构建树)。
