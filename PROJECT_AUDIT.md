# ArkTavern 项目审计报告

Version: 0.1
Date: 2026-07-15
Auditor: AI Agent

---

## 1. 审计范围

本报告针对 `D:\DevEco_studio\ArkTavern` 当前工程的真实状态进行审计,不涉及任何业务代码假设。审计目的是确认工程基线是否满足 ArkTavern 第一阶段开发要求。

---

## 2. 当前工程结构

ArkTavern 为 DevEco Studio 新建的 HarmonyOS NEXT 初始工程,仅包含默认模板。

```
ArkTavern/
├── AppScope/
│   ├── app.json5                         # 应用级配置(bundleName 等)
│   └── resources/base/
│       ├── element/string.json           # 应用名等字符串
│       └── media/                         # 应用图标资源
├── entry/
│   ├── src/
│   │   ├── main/
│   │   │   ├── ets/
│   │   │   │   ├── entryability/
│   │   │   │   │   └── EntryAbility.ets  # UIAbility 入口
│   │   │   │   ├── entrybackupability/
│   │   │   │   │   └── EntryBackupAbility.ets  # 备份扩展能力
│   │   │   │   └── pages/
│   │   │   │       └── Index.ets         # 默认 Hello World 页面
│   │   │   ├── resources/
│   │   │   │   ├── base/
│   │   │   │   │   ├── element/{color,float,string}.json
│   │   │   │   │   ├── media/{background,foreground,startIcon,...}.png
│   │   │   │   │   └── profile/{backup_config,main_pages}.json
│   │   │   │   └── dark/element/color.json
│   │   │   └── module.json5
│   │   ├── mock/mock-config.json5
│   │   ├── ohosTest/                     # UI 测试桩
│   │   └── test/                         # 本地单元测试桩
│   ├── build-profile.json5
│   ├── hvigorfile.ts
│   ├── obfuscation-rules.txt
│   └── oh-package.json5
├── hvigor/hvigor-config.json5
├── AGENTS.md
├── ARCHITECTURE.md
├── build-profile.json5
├── code-linter.json5
├── hvigorfile.ts
├── oh-package-lock.json5
└── oh-package.json5
```

---

## 3. SDK 与 API Version

| 项目 | 值 | 来源 |
|------|-----|------|
| Hvigor modelVersion | 6.1.1 | oh-package.json5 / hvigor-config.json5 |
| targetSdkVersion | 6.1.1(24) | build-profile.json5 |
| compatibleSdkVersion | 6.1.0(23) | build-profile.json5 |
| runtimeOS | HarmonyOS | build-profile.json5 |
| apiType | stageMode | entry/build-profile.json5 |
| useNormalizedOHMUrl | true | build-profile.json5 |
| caseSensitiveCheck | true | build-profile.json5 |

结论:工程基于 HarmonyOS NEXT 6.1.x(API 24 目标 / API 23 兼容),Stage 模型,符合 AGENTS.md 要求。所有新代码应面向 API 23+ 能力编写,使用前需确认 SDK 实际支持。

---

## 4. 应用与模块配置

### 4.1 应用级(AppScope/app.json5)

- bundleName: `com.example.arktavern`
- vendor: `example`
- versionCode: 1000000
- versionName: `1.0.0`
- buildVersion: `1`

风险提示:`com.example.*` 包名仅适用于开发期,发布前需改为正式包名。`example` vendor 同理。

### 4.2 模块级(entry/src/main/module.json5)

- module.name: `entry`,type: `entry`
- mainElement: `EntryAbility`
- deviceTypes: `["phone"]`(仅手机)
- installationFree: false
- abilities: 仅 `EntryAbility`,具备 `entity.system.home` + `ohos.want.action.home`(启动入口)
- extensionAbilities: `EntryBackupAbility`(type: backup)
- pages: `$profile:main_pages`

### 4.3 页面路由(resources/base/profile/main_pages.json)

```json
{ "src": ["pages/Index"] }
```

仅注册了一个页面。后续新增页面必须同步在此文件追加。

---

## 5. 当前默认页面与入口代码

### 5.1 EntryAbility.ets

标准 UIAbility 模板,生命周期方法齐全(onCreate / onDestroy / onWindowStageCreate / onWindowStageDestroy / onForeground / onBackground)。`onWindowStageCreate` 加载 `pages/Index`。`onCreate` 中调用 `setColorMode(COLOR_MODE_NOT_SET)`,为暗色模式预留了入口。

### 5.2 pages/Index.ets

默认 Hello World 模板,使用 `RelativeContainer` + `Text`,点击切换文本。无任何业务逻辑。

### 5.3 EntryBackupAbility.ets

备份扩展能力模板,`onBackup` / `onRestore` 均为空实现(仅日志)。

---

## 6. 当前依赖

### 6.1 根 oh-package.json5

```json5
{
  "modelVersion": "6.1.1",
  "devDependencies": {
    "@ohos/hypium": "1.0.25",
    "@ohos/hamock": "1.0.0"
  }
}
```

### 6.2 entry/oh-package.json5

```json5
{ "name": "entry", "version": "1.0.0", "dependencies": {} }
```

结论:工程零运行时依赖,仅含官方测试框架 hypium 与 mock 框架 hamock。第一阶段不需要引入任何第三方依赖,符合"不安装第三方依赖"原则。

---

## 7. 代码规范配置

### 7.1 code-linter.json5

- 扫描范围:`**/*.ets`
- 规则集:`plugin:@performance/recommended` + `plugin:@typescript-eslint/recommended`
- 安全规则全部启用(error):
  - `@security/no-unsafe-aes` / `no-unsafe-hash` / `no-unsafe-mac` / `no-unsafe-dh` / `no-unsafe-dsa` / `no-unsafe-ecdsa`
  - `@security/no-unsafe-rsa-encrypt` / `no-unsafe-rsa-sign` / `no-unsafe-rsa-key`
  - `@security/no-unsafe-dsa-key` / `no-unsafe-dh-key` / `no-unsafe-3des`

风险提示:API Key 加密存储必须使用符合上述安全规则的算法(AES-GCM/ChaCha20、RSA-OAEP 等),禁止使用 ECB、MD5、SHA1、3DES 等弱算法。这直接影响 storage/KeyStore 模块的设计。

### 7.2 混淆

entry/build-profile.json5 中 release 构建 `obfuscation.enable: false`(默认关闭)。发布前需评估开启。

---

## 8. 已存在的代码清单

| 文件 | 类型 | 状态 |
|------|------|------|
| EntryAbility.ets | UIAbility | 模板,需保留并扩展 |
| EntryBackupAbility.ets | BackupExtensionAbility | 模板,需保留 |
| Index.ets | Page | 模板,需替换 |
| mock-config.json5 | mock | 桩,暂保留 |
| Ability.test.ets / List.test.ets | 测试 | 桩,暂保留 |
| LocalUnit.test.ets / List.test.ets | 测试 | 桩,暂保留 |

---

## 9. 缺失模块(对照 ARCHITECTURE.md)

当前 `entry/src/main/ets/` 下仅存在 `entryability/`、`entrybackupability/`、`pages/`。以下目录全部缺失,需按阶段逐步创建:

| 目标目录 | 职责 | 第一阶段是否需要 |
|----------|------|------------------|
| models/ | 数据模型(interface/enum/class) | 是 |
| viewmodels/ | 页面状态管理 | 是 |
| services/ | 业务逻辑 | 是 |
| repositories/ | 数据访问抽象 | 是(轻量) |
| database/ | RDB 封装 | Phase 4 |
| storage/ | Preferences / KeyStore / 文件 | 是(KeyStore + Preferences) |
| network/core/ | HTTP / 超时 / 重试 | 是 |
| network/providers/ | Provider 适配器 | 是(OpenAI Compatible) |
| network/streaming/ | SSE 解析 | 是 |
| parser/character/ | 角色卡解析 | Phase 3 |
| parser/lorebook/ | 世界书解析 | Phase 6 |
| parser/png/ | PNG 元数据解析 | Phase 2+ |
| utils/ | 工具函数 | 是 |
| theme/ | 主题 | Phase 2+ |

第一阶段(Phase 0+1)实际需要的最小目录集合:`models/`、`services/`、`storage/`、`network/core/`、`network/providers/`、`network/streaming/`、`utils/`、`pages/`(已存在)、`viewmodels/`。其余按 DEVELOPMENT_PLAN.md 推进时再创建,避免空目录。

---

## 10. 与 AGENTS.md / ARCHITECTURE.md 的一致性核查

| 检查项 | 文档要求 | 实际状态 | 结论 |
|--------|----------|----------|------|
| 平台 | HarmonyOS NEXT | API 24/23,Stage | 一致 |
| 语言 | ArkTS | .ets | 一致 |
| 框架 | ArkUI | RelativeContainer 等 | 一致 |
| WebView | 禁止 | 无 | 一致 |
| 分层 | Page 禁止网络/数据库 | 仅模板,无违规 | 一致 |
| 数据库 | RDB | 未创建 | 待实现 |
| API Key | 安全存储,不入库 | 未实现 | 待实现 |
| 目录结构 | 见 AGENTS.md | 仅有模板目录 | 需按阶段补齐 |

潜在冲突:AGENTS.md 的"Project Structure"段落把 `Reference/` 列在工程内,而实际参考目录在工程外的 `D:\DevEco_studio\ArkTavern-Reference`。这不影响开发,但提示 Reference 不属于工程构建树,符合只读约束。

---

## 11. 构建风险与注意事项

### 11.1 高风险

1. **API Key 安全存储**:code-linter 启用了严格的安全规则,HarmonyOS 的 `@ohos.security.huks` 或 `@ohos.security.cryptoFramework` 必须使用合规算法模式(AES-GCM、RSA-OAEP),禁止 ECB/MD5/SHA1。需在 Phase 0 验证 huks/cryptoFramework API 在 API 23 的可用性。
2. **SSE 流式实现**:HarmonyOS `@ohos.net.http` 的流式能力需确认是否支持增量响应回调(`on('dataReceive')`)。若不支持,需退化为 `httpRequest` + 手动分块解析,或使用 `rcp`(Remote Communication Kit)。这是 Phase 1 的关键技术验证点。
3. **PNG 元数据解析**:角色卡 PNG 的 `tEXt`/`iTXt` chunk 解析需纯 ArkTS 实现,不能依赖 Node.js Buffer。Phase 2/3 需单独 PoC。

### 11.2 中风险

4. **包名 `com.example.arktavern`**:发布前必须修改,否则无法上架。开发期可暂留。
5. **deviceTypes 仅 phone**:若未来需支持平板/2in1,需扩展。当前符合"phone first"。
6. **混淆关闭**:release 构建未启用混淆,体积与安全风险增加。发布前评估。
7. **暗色模式**:`setColorMode(COLOR_MODE_NOT_SET)` 已留口子,但资源仅 `dark/element/color.json`,后续需补齐暗色资源。

### 11.3 低风险

8. **测试桩**:ohosTest / test 目录为默认桩,不影响构建,后续替换为真实测试。
9. **mock-config.json5**:默认 mock 桩,可保留或删除。

---

## 12. 审计结论

- 工程为纯净的 HarmonyOS NEXT 6.1.x Stage 模型初始工程,无遗留业务代码,无第三方依赖,适合作为 ArkTavern 起点。
- 当前不存在 models/services/network/storage/parser 等模块,需按第一阶段实际需求最小化创建。
- SDK 版本满足要求,但 SSE 流式与安全存储两处需要在 Phase 0/1 进行独立 PoC 验证。
- code-linter 的安全规则会直接约束 storage 层实现,需提前确认算法选型。
- AGENTS.md 与 ARCHITECTURE.md 与当前工程无硬性冲突,可作为开发指导。

建议第一个开发任务:Phase 0 的"SSE 流式接收 PoC",这是整个聊天链路的技术基线,风险最高、回滚成本最低。
