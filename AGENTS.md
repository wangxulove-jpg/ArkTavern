# ArkTavern AI Development Guide

## Project

Project Name:

ArkTavern

Target Platform:

HarmonyOS NEXT

Language:

ArkTS

Framework:

ArkUI

IDE:

DevEco Studio 6+

Purpose:

Build a native HarmonyOS NEXT AI Tavern client inspired by MiniTavern while using SillyTavern as the primary open-source logic reference.

This project is for personal use only.

------------------------------------------------------------

# Overall Goal

ArkTavern is NOT an Android port.

ArkTavern is NOT a React Native application.

ArkTavern is NOT a WebView wrapper.

ArkTavern is a fully native HarmonyOS NEXT application.

Only the business logic, data formats and interaction design may be referenced.

Everything else should be implemented using ArkTS.

------------------------------------------------------------

# Project Structure

ArkTavern/

AppScope/

entry/

ets/

pages/

components/

models/

services/

database/

storage/

network/

utils/

parser/

resources/

------------------------------------------------------------

# Reference Projects

Reference projects are READ ONLY.

Never modify them.

Reference/

MiniTavern/

SillyTavern/

Docs/

MiniTavern is used ONLY for:

• UI reference

• UX reference

• API behavior

• interaction flow

• feature discovery

Never copy code directly from MiniTavern.

------------------------------------------------------------

SillyTavern is the primary logic reference.

It may be used for:

Prompt Builder

Character Card parser

Lorebook

Preset

OpenAI compatible request

JSON format

Conversation structure

Macro replacement

Do not migrate Node.js code directly.

Rewrite everything in ArkTS.

------------------------------------------------------------

# Architecture

Presentation Layer

↓

Business Layer

↓

Storage Layer

↓

Network Layer

↓

AI Provider

Every layer must be independent.

No page should directly call network code.

------------------------------------------------------------

# Directory Responsibilities

pages/

Only UI.

Never contain business logic.

------------------------------------------------------------

components/

Reusable UI.

No network.

No storage.

------------------------------------------------------------

services/

Business logic.

PromptBuilder

CharacterService

ChatService

LorebookService

ModelService

------------------------------------------------------------

storage/

Preferences

Database

KeyStore

ImportExport

------------------------------------------------------------

network/

HTTP

SSE

Provider adapters

Retry

Timeout

------------------------------------------------------------

parser/

PNG parser

JSON parser

Character parser

Lorebook parser

------------------------------------------------------------

utils/

Helper functions only.

------------------------------------------------------------

# Coding Rules

Always use TypeScript style.

Avoid any.

Prefer interfaces.

Keep methods short.

Never use global mutable state.

Prefer dependency injection.

------------------------------------------------------------

# UI Rules

Use ArkUI components only.

Do NOT use WebView.

Prefer Navigation.

Prefer LazyForEach.

Use responsive layout.

Support phones first.

Dark mode ready.

------------------------------------------------------------

# Database

Use RDB.

Tables:

characters

messages

chats

lorebooks

presets

Never store API Keys in database.

------------------------------------------------------------

# API Keys

Always store securely.

Never hardcode.

Never commit.

Never print to logs.

------------------------------------------------------------

# AI Providers

Must support:

OpenAI Compatible

DeepSeek

OpenRouter

Claude

Gemini

Design provider adapters.

Never hardcode endpoints.

------------------------------------------------------------

# Streaming

Support SSE.

Incrementally update messages.

Never block UI.

------------------------------------------------------------

# Character Card

Support:

PNG

JSON

V2

V3

Convert everything into internal models.

------------------------------------------------------------

# Lorebook

Support:

keyword match

priority

constant entries

recursive scan (future)

------------------------------------------------------------

# Prompt Builder

System

↓

Character

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

Post Instructions

------------------------------------------------------------

# Macro Support

{{user}}

{{char}}

{{description}}

{{scenario}}

{{personality}}

{{lastMessage}}

------------------------------------------------------------

# Development Order

Phase 1

Model Settings

Chat UI

OpenAI Compatible

Character Import

JSON Parser

Database

Streaming

Phase 2

PNG Parser

Lorebook

Preset

Swipe

Export

Phase 3

Claude

Gemini

Group Chat

TTS

Image Generation

------------------------------------------------------------

# Agent Rules

Before writing code:

Read existing implementation.

Reuse project architecture.

Never duplicate logic.

Never create unnecessary files.

Never generate placeholder code.

Always finish one feature before starting another.

------------------------------------------------------------

# Commit Style

feat:

fix:

refactor:

docs:

style:

test:

------------------------------------------------------------

# Forbidden

Do NOT port Android code.

Do NOT port Java code.

Do NOT port Kotlin code.

Do NOT use React Native.

Do NOT use WebView.

Do NOT use Node.js runtime.

Do NOT modify Reference directory.

------------------------------------------------------------

# Priority

1.

Stable architecture.

2.

Readable code.

3.

Native HarmonyOS experience.

4.

Compatibility with SillyTavern data.

5.

Performance.

------------------------------------------------------------

# Final Objective

Install one HAP.

Import Character Card.

Configure API.

Start chatting.

No PC.

No Node.js.

Native HarmonyOS NEXT experience.

------------------------------------------------------------

# T-0.5 补充规则

以下规则由 T-0.5 确立,作为 Phase 1 起的开发约束补充,不修改前文已有规则。

## Reference 实际路径

参考目录实际位于工程外:

D:\DevEco_studio\ArkTavern-Reference

包含:
- MiniTavern/(APK 解压产物,仅 UX/功能参考)
- SillyTavern-release/(官方开源仓库全量源码,主要逻辑参考)

AGENTS.md 前文 "Project Structure" 中的 `Reference/` 段落仅作概念性描述,实际参考目录不属于工程构建树,只读,禁止修改。

详细参考映射见 REFERENCE_AUDIT.md 与 MIGRATION_MAP.md。

## Barrel Export

本项目暂不使用 barrel export。

禁止:
- 创建 `index.ets` 作为模块统一导出
- 创建统一 `exports.ets`
- 使用路径别名

采用直接相对路径导入:
- `import { Xxx } from '../models/Xxx'`
- `import { Xxx } from '../network/core/Xxx'`

理由:当前模块数量较少,直接路径更利于定位循环依赖与编译问题。后续模块稳定后再评估是否引入 barrel export。

## 空目录与占位文件

禁止:
- 预先创建空目录
- 创建占位文件(如空的 `.ets`、`README.md`、`.gitkeep`)
- 为"目录完整性"而创建无意义文件

目录按任务实际需求创建。当前阶段不需要的目录不得存在。

## 临时 PoC 文件规则

当前存在临时 PoC 文件:
- `pages/RealSsePocPage.ets`
- `viewmodels/RealSsePocViewModel.ets`
- `pages/Index.ets` 中的"真实 SSE 测试"入口
- `main_pages.json` 中 `pages/RealSsePocPage` 的注册

规则:
1. 临时 PoC 文件必须在其文件头注释中标注"临时开发测试"
2. 临时 PoC 文件不得作为正式功能的基础
3. Phase 1 正式 Provider / ModelService / ModelSettingsPage / 正式聊天页完成后,按 ARCHITECTURE.md T-0.5.6 的删除条件删除
4. `OpenAiUrlBuilder` 与 `OpenAiSseDeltaParser` 为过渡实现,Phase 1 评估是否迁移至 `network/providers/openai/`,不得复制出第二份相同逻辑

## 分层约束补充

在 AGENTS.md 前文 "Architecture" 与 "Directory Responsibilities" 基础上补充:

1. `pages/` 禁止直接调用 `AssetStoreKeyStore`
2. `pages/` 禁止直接调用 `HttpStreamTransport`
3. `pages/` 禁止直接调用任何 `network/` 模块
4. `pages/` 只能通过 `viewmodels/` 间接访问业务能力
5. `viewmodels/` 不直接依赖 `@ohos.net.http`
6. `viewmodels/` 不直接依赖 `@ohos.security.asset`
7. `viewmodels/` 通过 `services/` 访问 Provider / Storage
8. `components/` 不访问网络、数据库、安全存储
9. `services/` 不引用具体页面类
10. Provider 不直接操作 UI 状态

例外:`viewmodels/RealSsePocViewModel.ets` 为临时 PoC,直接依赖 `network/streaming/*`,Phase 1 正式 Provider 完成后删除。

详细的目录职责表、依赖方向、导入顺序、命名约定见 ARCHITECTURE.md 的 "T-0.5 分层目录与导出约定" 章节。

## 快速验证规则

1. 普通功能开发采用分级验证：
   - 编码过程中只做静态检查。
   - 完成一批相关修改后，仅执行一次 entry@default 增量编译。
   - 编译通过后，仅运行本任务直接相关测试。
   - 最后执行一次最小实机冒烟验证。

2. 默认禁止 clean build。仅在以下情况允许：
   - 修改构建配置、模块配置或签名配置；
   - 删除文件后存在旧产物引用；
   - 增量编译连续两次出现明确缓存异常；
   - Phase 完成后执行正式回归。

3. 不运行全部历史测试，除非：
   - Phase 完成；
   - 修改公共底层模块；
   - 用户明确要求全量回归。

4. 同一编译命令最多运行 3 次：
   - 第一次发现错误；
   - 第二次验证修复；
   - 第三次最终确认。
   不得无证据重复 clean、重装或改变构建方式。

5. 同一设备测试命令最多运行 2 次。
   若两次均为相同环境错误，记录并停止，不再猜测重试。

6. 以下已知错误视为环境限制：
   - SDK component missing
   - Cannot find module OpenHarmonyTestRunner
   - Test Runner HAP 构建或安装异常
   当 entry@ohosTest 已编译通过且错误与本次代码无直接关系时，不阻塞当前功能交付。

7. 遇到 App died：
   - 先读取 faultlog；
   - 未取得直接错误证据前，不得猜测是进程冲突、HAP 安装顺序或 force-stop 问题；
   - 相同 faultlog 不重复分析。

8. 普通任务仅验证受影响链路。
   页面功能的实机验证控制在 3–6 个关键操作，不做全应用巡检。