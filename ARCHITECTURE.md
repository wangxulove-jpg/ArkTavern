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