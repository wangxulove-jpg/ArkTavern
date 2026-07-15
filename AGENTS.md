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

Maximum function length:

100 lines

Maximum file length:

600 lines

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