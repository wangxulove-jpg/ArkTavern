# ArkTavern Architecture

Version

0.1

---

# Vision

ArkTavern is a fully native HarmonyOS NEXT AI roleplay client.

It provides a mobile-first experience while remaining compatible with
SillyTavern data formats.

No WebView.

No Node.js runtime.

No React Native.

Everything is implemented using ArkTS.

---

# Design Principles

Native First

Layered Architecture

Data Driven

Provider Independent

Offline First

Simple UI

Maintainable Code

---

# Architecture

                UI
                 │
                 ▼
        ViewModel / State
                 │
                 ▼
         Business Services
                 │
     ┌───────────┴────────────┐
     ▼                        ▼
 Storage                 AI Provider
     │                        │
     ▼                        ▼
 Database              HTTP/SSE
                 │
                 ▼
            Model APIs

---

# Module Overview

UI

Business

Storage

Network

Parser

Utility

---

# UI Layer

Responsible for

Navigation

Pages

Dialogs

Animations

Theme

Components

Contains

pages/

components/

Never

Database

Network

Business logic

---

# Business Layer

Contains

ChatService

CharacterService

PromptBuilder

LorebookService

ModelService

ImportExportService

ConversationService

Business rules only.

---

# Storage Layer

Responsible for

Preferences

Database

KeyStore

Import Export

Cache

No UI.

---

# Network Layer

Responsible for

HTTP

Streaming

Retry

Timeout

Authentication

Provider abstraction

Never expose HTTP directly to pages.

---

# Parser Layer

Character Card

PNG metadata

JSON

Lorebook

Preset

Future

ZIP package

---

# Utility Layer

Logger

Time

String

UUID

Token Counter

Image Helper

No business logic.

---

# Folder Layout

entry/src/main/ets

pages/

components/

models/

services/

storage/

network/

parser/

database/

utils/

theme/

assets/

---

# Navigation

Splash

↓

Home

↓

Character

↓

Chat

↓

Settings

↓

Model Settings

↓

Lorebook

↓

About

---

# Data Flow

User

↓

ChatPage

↓

ChatService

↓

PromptBuilder

↓

Provider

↓

Streaming

↓

Database

↓

UI Update

---

# Character

Character

↓

Chat

↓

Message

↓

Lorebook

↓

Prompt

↓

AI

↓

Reply

---

# Database

characters

id

name

avatar

json

created

updated

---

chats

id

characterId

title

created

updated

---

messages

id

chatId

role

content

extra

created

---

lorebooks

id

name

json

enabled

---

presets

id

name

json

---

# Storage

Preferences

Theme

Language

Current Model

Current Character

Current Chat

Keystore

API Keys

Secrets

Never store secrets in database.

---

# Providers

Provider Interface

↓

OpenAI Compatible

↓

DeepSeek

↓

OpenRouter

↓

Claude

↓

Gemini

Future

Ollama

LM Studio

AnythingLLM

---

# Prompt Builder

System Prompt

↓

Character Description

↓

Personality

↓

Scenario

↓

Lorebook

↓

Examples

↓

History

↓

Current User Input

↓

Post Prompt

---

# Streaming

Request

↓

SSE Parser

↓

Delta

↓

Message Buffer

↓

UI

↓

Database

---

# Character Card

Support

PNG

JSON

V2

V3

Everything converted into

CharacterModel

---

# Future Plugin System

Plugin API

↓

Command

↓

Hook

↓

Prompt Modifier

↓

Tool Call

---

# Error Handling

Network

Retry

Timeout

Authentication

Invalid Character

Import Failure

Parser Failure

Provider Failure

---

# Logging

Debug

Warning

Error

Never print API Keys.

Never print secrets.

---

# Performance

LazyForEach

Incremental Rendering

Image Cache

Streaming Rendering

Paged Messages

Database Index

---

# Theme

Light

Dark

Future

Material You

Harmony Dynamic Color

---

# Security

HTTPS Preferred

API Keys encrypted

No plaintext secrets

Import validation

JSON validation

---

# Development Priority

Phase 1

Basic Chat

↓

Model Settings

↓

Streaming

↓

Character Import

↓

Database

↓

Prompt

---

Phase 2

Lorebook

↓

Preset

↓

Swipe

↓

Export

↓

Image Import

---

Phase 3

Claude

↓

Gemini

↓

Group Chat

↓

Voice

↓

Image Generation

↓

Plugin System

---

# Success Criteria

One HAP

↓

Import Character

↓

Configure Model

↓

Start Chat

↓

Smooth Streaming

↓

Native HarmonyOS Experience

---

# T-0.5 分层目录与导出约定

本章节由 T-0.5 确立,作为 Phase 1 起所有新代码的目录、依赖与导入基线。
本章节不重写前文,仅补充前文未明确的工程实际状态与约定。

---

## T-0.5.1 当前实际目录结构(截至 Phase 0 完成)

以 `entry/src/main/ets/` 为根:

```
entry/src/main/ets/
├── entryability/                 # UIAbility 生命周期入口(模板)
│   └── EntryAbility.ets
├── entrybackupability/           # 备份扩展能力(模板)
│   └── EntryBackupAbility.ets
├── models/                       # 跨层数据模型与错误模型
│   ├── NetworkError.ets
│   └── SecureStorageError.ets
├── network/
│   ├── core/
│   │   └── HttpClient.ets        # HTTP 抽象接口
│   └── streaming/
│       ├── HttpStreamTransport.ets
│       ├── OpenAiSseDeltaParser.ets   # PoC/Provider 格式解析过渡实现
│       ├── OpenAiUrlBuilder.ets       # PoC/Provider URL 构建过渡实现
│       ├── SseParser.ets
│       ├── SseTypes.ets
│       ├── StreamTransportTypes.ets
│       └── Utf8StreamDecoder.ets
├── pages/
│   ├── Index.ets                 # 当前入口页(含临时 PoC 入口)
│   └── RealSsePocPage.ets        # 临时 SSE PoC 页面
├── storage/
│   ├── AliasBuilder.ets
│   ├── AssetStoreKeyStore.ets
│   └── KeyStore.ets
├── utils/
│   ├── Logger.ets
│   ├── Time.ets
│   └── Uuid.ets
└── viewmodels/
    └── RealSsePocViewModel.ets   # 临时 SSE PoC ViewModel
```

当前不存在以下目录(按需创建,禁止预先创建空目录):
`components/`、`services/`、`network/providers/`、`repositories/`、`database/`、`parser/`、`theme/`、`assets/`。

---

## T-0.5.2 目录职责表

| 目录 | 职责 | 当前状态 | 禁止 |
|------|------|---------|------|
| `entryability/` | UIAbility 生命周期入口,仅初始化与页面加载 | 模板已存在 | 承载业务逻辑 |
| `entrybackupability/` | HarmonyOS 备份扩展能力 | 模板已存在 | 当前保留模板,后续 BackupService 再接入 |
| `pages/` | ArkUI 页面,仅布局/事件转发/状态展示 | Index + RealSsePocPage | 直接操作 HTTP / Asset Store / RDB |
| `components/` | 可复用 ArkUI 组件 | Phase 1 创建 | 访问网络/数据库/安全存储 |
| `viewmodels/` | 页面状态与用户操作协调,调用 Service | 仅 RealSsePocViewModel(临时) | 直接依赖 @ohos.net.http / Asset Store(PoC 例外须标记临时) |
| `services/` | 业务用例协调,调用 Provider/Repository/Parser/Storage | Phase 1 创建 | 引用具体页面类 |
| `models/` | 跨层数据模型、错误模型、枚举 | NetworkError + SecureStorageError | 依赖页面 / 依赖 ArkUI API |
| `network/core/` | HTTP 抽象、错误映射、超时、重试 | HttpClient | 包含 Provider 业务字段 |
| `network/streaming/` | 流式传输、UTF-8 解码、SSE 帧解析 | 7 个文件 | — |
| `network/providers/` | 正式 Provider 适配器 | Phase 1 创建 | 依赖页面 |
| `storage/` | Asset Store / Preferences / 文件导入导出 | KeyStore + AliasBuilder + AssetStoreKeyStore | 包含业务页面状态 |
| `repositories/` | RDB 或其他持久层访问抽象 | Phase 4 创建 | 依赖 viewmodels |
| `database/` | RDB 初始化、schema、migration | Phase 4 创建 | — |
| `parser/` | 外部格式解析(角色卡/世界书/PNG) | Phase 3/6 创建 | — |
| `theme/` | 主题与资源映射 | 正式 UI 需要时创建 | — |
| `utils/` | 无业务状态的通用工具 | Logger / Uuid / Time | 演变成杂项目录 |

---

## T-0.5.3 依赖方向

```
pages
  ↓
viewmodels
  ↓
services
  ↓
network/providers / repositories / storage / parser
  ↓
network/core / network/streaming / database / HarmonyOS SDK
```

`models` 与 `utils` 可被多个上层模块使用,但必须避免循环依赖。

明确禁止的依赖方向:
1. `network` 依赖 `pages`
2. `storage` 依赖 `pages`
3. `repositories` 依赖 `viewmodels`
4. `models` 依赖 ArkUI 页面
5. `components` 直接调用 Provider
6. `pages` 直接调用 `AssetStoreKeyStore`
7. `pages` 直接调用 `HttpStreamTransport`
8. Provider 直接操作 UI 状态
9. Service 引用具体页面类
10. 任何循环依赖

例外:`viewmodels/RealSsePocViewModel.ets` 为临时 PoC,直接依赖 `network/streaming/*`,Phase 1 正式 Provider 完成后删除。

---

## T-0.5.4 导入约定

本项目暂不使用 barrel export。

明确采用直接相对路径导入:

```
import { Xxx } from '../models/Xxx'
import { Xxx } from '../network/core/Xxx'
import { Xxx } from '../utils/Logger'
```

理由:
1. 当前模块数量较少
2. ArkTS 编译与循环依赖问题更容易定位
3. 避免 `index.ets` 引发隐式依赖
4. 后续模块稳定后再评估 barrel export

要求:
- 不创建 `index.ets`
- 不创建统一 `exports.ets`
- 每个文件使用明确相对路径导入
- 同一模块内导入顺序保持一致:
  1. HarmonyOS SDK(`@kit.*` / `@ohos.*`)
  2. `models/`
  3. `network/core` / `network/streaming` / `storage/`
  4. `utils/`
- 禁止过深且重复的混乱路径
- 不允许路径别名,除非后续确认 DevEco/Hvigor 正式支持且有明确收益

---

## T-0.5.5 命名约定

| 类型 | 命名规范 | 示例 |
|------|---------|------|
| 页面 | `XxxPage.ets` | `ChatPage.ets`、`ModelSettingsPage.ets` |
| 组件 | `XxxComponent.ets` 或明确业务名 | `MessageBubble.ets`、`ChatInput.ets` |
| ViewModel | `XxxViewModel.ets` | `ChatViewModel.ets` |
| Service | `XxxService.ets` | `ChatService.ets`、`ModelService.ets` |
| Repository | `XxxRepository.ets` | `CharacterRepository.ets` |
| Provider | `XxxProvider.ets` | `OpenAIProvider.ets`、`ClaudeProvider.ets` |
| Parser | `XxxParser.ets` / `XxxReader.ets` | `CharacterCardParser.ets`、`PngMetadataReader.ets` |
| 模型 | `Xxx.ets` / `XxxConfig.ets` / `XxxError.ets` / `XxxType.ets` | `NetworkError.ets`、`ProviderConfig.ets` |
| 测试 | `Xxx.test.ets` | `NetworkError.test.ets` |

通用规则:
- 文件名使用 PascalCase
- 类、接口、枚举使用 PascalCase
- 方法和变量使用 camelCase
- 常量使用 UPPER_SNAKE_CASE
- 不使用 `service1`、`utils2`、`common`、`helper2` 等模糊名称
- `Helper` 仅在职责无法准确命名时使用

---

## T-0.5.6 临时 PoC 文件生命周期

以下文件为临时开发文件,Phase 1 正式功能完成后删除:

- `pages/RealSsePocPage.ets`
- `viewmodels/RealSsePocViewModel.ets`
- `pages/Index.ets` 中的"真实 SSE 测试"入口按钮
- `resources/base/profile/main_pages.json` 中 `pages/RealSsePocPage` 的注册

删除条件(全部满足后才允许删除):
1. 正式 `OpenAIProvider` 完成
2. `ModelService` 完成
3. `ModelSettingsPage` 完成
4. `QuickChatPage` 或正式 `ChatPage` 完成真实流式验证
5. 正式页面能覆盖以下能力:
   - URL 校验
   - 流式显示
   - abort
   - 401 错误
   - [DONE]

`OpenAiUrlBuilder.ets` 与 `OpenAiSseDeltaParser.ets` 不必直接删除。
Phase 1 应评估:
- 是否迁移至 `network/providers/openai/`
- 如果正式 Provider 可复用,则保留并重命名位置
- 不得复制出第二份相同逻辑

---

## T-0.5.7 Phase 1 首批允许创建的目录

Phase 1 开始时才创建:

- `entry/src/main/ets/network/providers/`
- `entry/src/main/ets/services/`
- `entry/src/main/ets/components/`

`viewmodels/` 与 `pages/` 已存在,继续使用。

Phase 1 暂不创建(除非具体任务确实需要):
- `repositories/`
- `database/`
- `parser/`
- `theme/`

禁止预先创建空目录或占位文件。