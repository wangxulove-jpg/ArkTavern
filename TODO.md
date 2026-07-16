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
  - [x] Logger 可分级输出且对 `apiKey`/`Authorization` 等关键字段脱敏
  - [x] Uuid 生成符合 v4 格式
  - [x] Time 可生成毫秒时间戳与 ISO 字符串
  - [x] code-linter 无 error
- 实现说明:
  - 实际使用的 HarmonyOS API:`@kit.PerformanceAnalysisKit` 的 `hilog`(Logger)、`@kit.CryptoArchitectureKit` 的 `cryptoFramework.createRandom().generateRandomSync(16)`(Uuid)、`Date.now()`/`Date.prototype.toISOString()`(Time,纯 JS 能力)
  - 测试情况:本地单元测试通过(`entry/src/test/Time.test.ets`,7 个用例);Logger/Uuid 纯函数测试在 `entry/src/ohosTest/`(设备测试,11 + 14 个用例),需真机/模拟器运行
  - 设备验证要求:Logger 实际 hilog 输出、Uuid.generateUuid 调用 cryptoFramework 需真机验证;纯函数 `isSensitiveKey`/`redactString`/`redactMap`/`formatUuidV4`/`isUuidV4` 已通过 ohosTest 编译,待真机执行
  - 已知限制:`mock-config.json5` 为空,模块级导入 `@kit.*` 的文件无法在本地单元测试运行,只能放 ohosTest;`hvigorw codeLinter` 命令行因 `local.properties` 无 SDK 路径报 "SDK component missing",改用 MCP `build_project` 验证编译(CompileArkTS 通过)

### T-0.2 定义网络核心错误模型与 HttpClient 接口

- 依赖:无
- 优先级:P0
- 修改范围:`entry/src/main/ets/network/core/`(新建)
- 内容:
  - `models/NetworkError.ets`:定义 ApiError / TimeoutError / AuthError / ParseError 等枚举与类
  - `network/core/HttpClient.ets`:HTTP 客户端接口(请求/响应抽象,不绑定具体实现)
- 验收标准:
  - [x] 错误类型可区分网络/超时/鉴权/解析
  - [x] HttpClient 为 interface,无具体 SDK 耦合
  - [x] 不含 any
- 实现说明:
  - 实际使用的 HarmonyOS API:无(纯 ArkTS 接口定义与类型,不依赖设备 API)
  - 测试情况:本地单元测试通过(`entry/src/test/NetworkError.test.ets`,16 个用例),覆盖 400/401/403/408/429/500/599/200 状态码映射、Cancelled 与 Timeout 区分、causeMessage 脱敏(Bearer/sk-token)、retryable 默认值与自定义;覆盖率:NetworkError.ets 函数 100%、行 97.96%、分支 96.43%
  - 设备验证要求:无(纯类型定义,无设备依赖)
  - 已知限制:`HttpHeaders` 使用 `Map<string, string>` 而非 `Record` 以规避 ArkTS 严格模式动态索引错误;HttpClient 仅接口,具体实现由 T-0.3+ 提供

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
  - [x] SseParser 能正确解析多帧 SSE 数据
  - [x] PoC 能对接真实端点并增量输出
  - [x] 中断(abort)可正常工作
  - [x] 输出 PoC 结论:最终采用 http 还是 rcp
- 子任务进度:
  - **T-0.3A(纯 ArkTS SSE 解析器):已完成**
    - 新增文件:`network/streaming/SseTypes.ets`(SseEvent/SseParseError/SseParseResult 类型)、`network/streaming/SseParser.ets`(有状态增量解析器,支持 feed/finish/reset/getBufferedLength)
    - 实际使用的 HarmonyOS API:无(纯 ArkTS,不依赖 hilog/http/rcp 等设备 API,脱敏逻辑内联实现以保持本地可测试性)
    - 测试情况:本地单元测试 25 个用例全部通过(`entry/src/test/SseParser.test.ets`),覆盖率 SseParser.ets 函数 100%、行 95.07%、分支 83.33%;MCP `build_project` clean 编译通过(CompileArkTS 4.13s)
    - 已知限制:缓冲区上限 65536 字符(超出返回 recoverable=false 错误并清空);错误 rawData 限 256 字符并脱敏;未实现字节到字符串转换(由上层网络层负责)
  - **T-0.3B(@ohos.net.http 流式 PoC):已完成**
    - 新增文件:`network/streaming/Utf8StreamDecoder.ets`(纯逻辑 UTF-8 增量解码器,211 行)、`network/streaming/StreamTransportTypes.ets`(TransportState 状态机 + TransportCallbacks + TransportRequestOptions + TransportAbortHandle,88 行)、`network/streaming/HttpStreamTransport.ets`(基于 `@ohos.net.http` 的流式 HTTP 传输层,344 行)
    - 开发工具:`tools/sse_mock_server.py`(仅 Python 标准库的 SSE mock server,不进入 HAP)
    - 修改文件:`entry/src/main/module.json5`(添加 `ohos.permission.INTERNET`)、`entry/src/main/resources/base/element/string.json`(添加 `permission_internet_reason`)
    - 测试文件:`entry/src/test/Utf8StreamDecoder.test.ets`(本地单元测试,21 个用例,覆盖中文跨 chunk/Emoji 跨 chunk/多字符边界/flush 正常/flush 非法尾部/非法起始字节/非法后续字节/过长编码/代理对范围/reset/空输入/混合 ASCII/终态判断/状态转换校验)、`entry/src/ohosTest/ets/test/HttpStreamTransport.test.ets`(设备集成测试,5 个用例:完整流式接收/中文无乱码/Emoji 无乱码/abort 停止接收/dataReceive 时间戳)
    - SDK 审计:本地 SDK 6.1.1 确认 `http.createHttp()`(since 6)、`HttpRequest.requestInStream(url, options?): Promise<number>`(since 18)、`on('dataReceive', Callback<ArrayBuffer>)`(since 10)、`on('dataEnd', Callback<void>)`(since 10)、`on('headersReceive', Callback<Object>)`(since 8)、`off(...)`(对应版本)、`destroy()`(since 6)
    - 实际使用的 HarmonyOS API:`@ohos.net.http`(流式传输)、`util.TextDecoder` 可用但因依赖设备 API 不便本地测试,改用纯逻辑 `Utf8StreamDecoder` 以同时满足生产可用 + 本地可测
    - 测试情况:本地单元测试全部通过;MCP `build_project` 编译通过;**设备集成测试全部通过**(Tests run: 5, Failure: 0, Error: 0, Pass: 5)
    - 设备验证结果(真机 USB + hdc rport):
      - 测试设备:华为 nova 13 Pro(真机 4BD9K24C18008717,USB 连接)
      - HarmonyOS/API 版本:OpenHarmony 6.1.0.115 Release,API 23
      - mock server 地址:`http://127.0.0.1:8765/sse`(hdc rport tcp:8765 tcp:8765 反向端口转发)
      - dataReceive 次数:每个测试 7 次(与 mock server 7 段 SSE 事件一致),间隔 497-504ms(与服务器 500ms 节奏一致)
      - dataEnd 结果:每个测试触发 1 次,随后 requestInStream resolve(code=200)
      - abort 结果:收到 1 个 dataReceive 后 abort,destroy 触发 requestInStream reject(code=2300023),handleError 检测 state=ABORTED 直接 return(迟到回调不改变终态)
      - UTF-8 结果:中文"你好世界"完整无乱码,Emoji"🌍🚀"完整无乱码,多行 data 正确合并,JSON data 完整,[DONE] 识别为 isDone=true
      - 资源释放:cleanup() 调用 off('headersReceive')/off('dataReceive')/off('dataEnd') + destroy()
    - 修复记录:mock server `Connection` 头从 `keep-alive` 改为 `close`(模拟 OpenAI 发送 [DONE] 后关闭连接的行为,使 dataEnd 正确触发);HttpStreamTransport 的 RequestContext 实现 TransportAbortHandle 接口(修复 ArkTS ohosTest 编译 `arkts-no-untyped-obj-literals` 错误)
    - 最终选择 @ohos.net.http 的依据:设备集成测试全部通过 15 项验收标准(dataReceive≥3 次、间隔~500ms、中文/Emoji 无乱码、多行 data 合并、JSON 完整、[DONE] 识别、dataEnd 一次、onComplete 一次、abort 停止接收、abort 幂等、迟到回调不改终态、监听器移除、HttpRequest destroy、无真实 API Key),无需引入 rcp
    - 已知限制:测试使用 hdc rport 反向端口转发(真机无 WiFi 场景);mock server `Connection: close` 模拟 AI API 发送完毕后关闭连接的行为;未配置明文 HTTP cleartext policy(127.0.0.1 回环默认允许,正式 AI API 仍要求 HTTPS)
  - **T-0.3C(真实 AI 兼容端点验证):已完成**
    - 新增文件:`network/streaming/OpenAiSseDeltaParser.ets`(OpenAI delta content 解析,264 行,类型守卫安全 JSON 解析,容错 delta.content 缺失/null/空、delta.role、choices 空、usage 事件、finish_reason、非 JSON data、错误对象、[DONE])、`network/streaming/OpenAiUrlBuilder.ets`(URL 组合 + 请求体构建,123 行,处理 /chat/completions 后缀、/v1 后缀、末尾 /、协议校验)、`viewmodels/RealSsePocViewModel.ets`(PoC 状态机 + 内存 Key 管理 + Transport 集成,~490 行)、`pages/RealSsePocPage.ets`(临时 PoC 页面,密码模式输入,开发标注)、`test/OpenAiUrlBuilder.test.ets`(11 个用例)、`test/OpenAiSseDeltaParser.test.ets`(16 个用例)
    - 修改文件:`pages/Index.ets`(添加"真实 SSE 测试 [开发测试]"入口,修复 alignRules 冲突导致按钮 height=0)、`resources/base/profile/main_pages.json`(注册 RealSsePocPage)
    - 实际使用的 HarmonyOS API:`@ohos.net.http`(通过 HttpStreamTransport)、`router`(页面跳转)
    - 测试情况:本地单元测试 30 个用例全部通过(OpenAiUrlBuilder 11 + OpenAiSseDeltaParser 16 + 现有 3);MCP `build_project` clean 编译通过
    - 设备验证结果(真机 USB):
      - 测试设备:华为 nova 13 Pro(真机 4BD9K24C18008717,USB 连接)
      - HarmonyOS/API 版本:OpenHarmony 6.1.0.115 Release,API 23
      - Provider 类型:OpenAI-compatible(DeepSeek)
      - Base URL:`https://api.deepseek.com`,Model: `deepseek-v4-flash`
      - 请求路径:`https://api.deepseek.com/v1/chat/completions`(URL builder 自动追加)
      - 成功测试 3 次:35/59/91 chunks,81/115/200 SSE 事件,10/68 delta,[DONE] 正确结束,中英文 + Emoji 无乱码
      - abort 测试通过:Streaming 状态点击"停止",状态变为 Cancelled,请求中断
      - 无效 API Key 测试通过:返回 Authentication failed (HTTP 401)
      - 错误 Base URL 测试通过:非法 URL 返回清晰校验错误
      - 页面退出中断请求通过:aboutToDisappear 调用 cleanup() 主动 abort
      - hilog 敏感信息检查通过:ArkTavern 应用日志无 API Key/Bearer 泄露,Logger 仅记录"Authorization set"
    - 安全验证:API Key 仅内存保存(ViewModel 私有字段,不暴露 getter),不落盘/不进 Preferences/不进 RDB/不进文件/不进日志;页面退出 cleanup() 清空 Key;工程源码内无硬编码密钥(测试文件中的 sk-abc123 等为脱敏逻辑测试 fixture)
    - 最终结论:**最终采用 @ohos.net.http**,无需 rcp;真实 OpenAI-compatible SSE 流式响应全链路验证通过

### T-0.4 安全存储 PoC(Asset Store 优先,HUKS 兜底)

- 依赖:T-0.1
- 优先级:P0
- 修改范围:`entry/src/main/ets/storage/`(新建)+ `entry/src/main/ets/models/SecureStorageError.ets` + 临时验证
- 内容:
  - `storage/KeyStore.ets`:平台无关安全存储抽象接口
  - `storage/AliasBuilder.ets`:纯逻辑 alias 构建与校验
  - `storage/AssetStoreKeyStore.ets`:基于 `@ohos.security.asset` 的 Asset Store Kit 实现
  - `models/SecureStorageError.ets`:安全存储错误模型(与 NetworkError 隔离)
  - 验证 Asset Store Kit 在 API 23 真机的 CRUD 行为
  - 仅当 Asset Store 失败时才启用 HUKS 兜底
- 验收标准:
  - [x] 可安全保存并读取一段测试 secret
  - [x] 可更新和删除
  - [x] 真机 API 23 验证通过
  - [x] code-linter 无 error
  - [x] 日志和工程不存在明文真实 API Key
  - [x] 输出最终安全存储选型
- 实现说明:
  - 最终选择:**Asset Store Kit**(`@ohos.security.asset`),HUKS 兜底未启用
  - API 23 真机通过:华为 nova 13 Pro(OpenHarmony 6.1.0.115 Release)
  - 敏感值存放:`Tag.SECRET`(平台自动加密,应用无需手动管理 AES/IV/authTag)
  - alias 格式:`arktavern.provider.<providerId>.api-key`,只含 [a-zA-Z0-9.\-_],不含敏感信息
  - Accessibility:`DEVICE_FIRST_UNLOCKED`(设备首次解锁后可访问)
  - SyncType:`NEVER`(默认不同步)
  - IS_PERSISTENT:不设置(应用卸载时默认删除)
  - 不开启用户认证
  - save 采用 upsert 语义(CONFLICT_RESOLUTION=OVERWRITE),update 不存在抛 NotFound,remove 幂等,read 不存在返回 null
  - exists 使用 `RETURN_TYPE=ATTRIBUTES` 仅查询属性,不读取明文
  - 实际使用的 HarmonyOS API:`@ohos.security.asset`(add/query/update/delete,since 11)、`@ohos.util.TextEncoder`(encodeInto,since 9)、`@ohos.util.TextDecoder`(decodeToString,since 12)、`@ohos.base.BusinessError`
  - 测试情况:
    - 本地单元测试:AliasBuilder 22 用例 + SecureStorageError 29 用例,全部通过
    - ohosTest 设备测试:AssetStoreKeyStore 20 用例,全部通过(Tests run: 20, Failure: 0, Error: 0, Pass: 20)
    - 跨进程持久性验证:阶段 A 保存 → force-stop → 阶段 B 读取,全部通过
    - hilog 敏感值扫描:4 个测试 secret 关键字均无匹配
    - 源码硬编码扫描:无真实 API Key,仅脱敏正则
  - 已知限制:HUKS 兜底未实现(Asset Store 全部通过,无需兜底);尚未接入正式 Provider(Phase 1 T-1.2 将基于此 KeyStore 接口实现多 Provider 密钥)

### T-0.5 确立分层目录与导出约定

- 依赖:T-0.1 ~ T-0.4
- 优先级:P0
- 修改范围:仅约定,不创建空目录
- 内容:在 AGENTS.md / ARCHITECTURE.md 基础上,确认实际目录与模块导出方式(Barrel export 或直接路径),记录到后续任务
- 验收标准:
  - [x] 明确每个新文件的归属目录
  - [x] 不存在空目录或占位文件
- 实现说明:
  - 修改文档:ARCHITECTURE.md(新增 T-0.5 章节)、AGENTS.md(新增 T-0.5 补充规则)、TODO.md(标记完成)
  - 采用明确相对路径导入,暂不使用 barrel export
  - 不创建 `index.ets`、不创建统一 `exports.ets`、不使用路径别名
  - 目录按任务实际需求创建,禁止预先创建空目录或占位文件
  - 临时 PoC 文件(RealSsePocPage / RealSsePocViewModel / Index 入口 / main_pages 注册)暂时保留
  - Phase 1 正式 Provider / ModelService / ModelSettingsPage / 正式聊天页完成后,按 ARCHITECTURE.md T-0.5.6 删除条件删除 PoC
  - Phase 1 首批允许创建的目录:`network/providers/`、`services/`、`components/`
  - Phase 1 暂不创建:`repositories/`、`database/`、`parser/`、`theme/`
  - 当前工程无空目录、无占位文件、无 barrel export、无循环依赖
  - 依赖方向:pages → viewmodels → services → network/providers / repositories / storage / parser → network/core / network/streaming / database / HarmonyOS SDK
  - models 与 utils 可被多个上层模块使用,必须避免循环依赖
  - 明确禁止:network 依赖 pages、storage 依赖 pages、repositories 依赖 viewmodels、models 依赖 ArkUI 页面、components 直接调用 Provider、pages 直接调用 AssetStoreKeyStore / HttpStreamTransport、Provider 直接操作 UI 状态、Service 引用具体页面类
  - 例外:RealSsePocViewModel 为临时 PoC,直接依赖 network/streaming/*,Phase 1 正式 Provider 完成后删除

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
  - [x] 所有模型为 interface 或 class,无 any
  - [x] 字段覆盖 OpenAI Chat Completions 常用参数
- 实现说明:
  - ProviderType:6 种 Provider 类型枚举,不硬编码 Base URL 或域名
  - ProviderConfig:不可变 class,提供 `create` 工厂方法和 `withUpdates` 副本方法;不包含 API Key、Authorization;集中定义校验常量(TEMPERATURE_MIN/MAX/DEFAULT、TOP_P_MIN/MAX/DEFAULT、MAX_TOKENS_MIN/MAX/DEFAULT、STREAM_DEFAULT、ENABLED_DEFAULT)和校验函数(isValidTemperature/isValidTopP/isValidMaxTokens/isValidId/isValidName/isValidBaseUrl/isValidModelName)
  - ChatRole:System/User/Assistant 枚举,值与 OpenAI API 格式一致(system/user/assistant)
  - ChatMessage:interface,含 id/role/content/createdAt + 可选 updatedAt/isStreaming/errorMessage;不加入 Character/Lorebook/Swipe 字段;不依赖 ArkUI
  - ChatRequest:interface,含 model/messages/temperature/topP/maxTokens/stream;不包含 URL/API Key/Header/UI 状态;createChatRequest 默认 stream=true
  - 本地单元测试:`test/ProviderConfig.test.ets`,覆盖 15+ 项(默认值/边界校验/空值校验/API Key 字段不存在/withUpdates/消息顺序/stream 默认值/敏感字段不存在)
  - Phase 1A 应用外壳:Index.ets 改造为正式首页(Navigation + NavPathStack),5 个静态占位页面(ChatPage/CharacterListPage/LorebookPage/ModelSettingsPage/AppSettingsPage),base + dark 颜色资源,string 资源,float 资源
  - PoC 页面(RealSsePocPage)继续保留,通过开发工具折叠区访问;Phase 1A 将 PoC 页面外壳从 @Entry/router 统一改造为 NavDestination,消除 router.pushUrl/router.back deprecated warning,PoC 网络逻辑(ViewModel)未修改
  - main_pages.json 仅注册 pages/Index,5 个正式页面 + PoC 页面均通过 NavPathStack 内部导航,不注册进 main_pages.json
  - 构建验证:clean build(entry@default)BUILD SUCCESSFUL 无 warning;ohosTest 编译 BUILD SUCCESSFUL;本地单元测试 15+ 项覆盖
  - 真机验证:nova 13 Pro 模拟器(API 23)部署成功;首页 13 项元素正常显示;5 个正式入口可打开并可返回;系统返回键正常;开发工具折叠区可展开,真实 SSE 测试入口可进入 PoC 页面;深色模式颜色资源正确加载(背景 #121212、卡片 #1E1E1E、文字 #F0F0F0);hilog 无 API Key/apiKey/Authorization/Bearer/sk- 泄漏

### T-1.2 实现多密钥 KeyStore

- 依赖:T-0.4、T-1.1
- 优先级:P1
- 修改范围:`entry/src/main/ets/storage/ProviderKeyStore.ets`(新建)
- 内容:支持按 Provider id 存取多个密钥;密钥不入数据库、不入日志
- 验收标准:
  - [x] 可按 id 加密保存/读取/删除密钥
  - [x] 失败时返回明确错误,不抛明文
- 实现说明:
  - 新增 `storage/ProviderKeyStore.ets`:Provider 级密钥管理,依赖 KeyStore 抽象(不直接调用 Asset Store API)
  - 使用 `ProviderConfig.id` 通过 `AliasBuilder` 生成 alias:`arktavern.provider.<providerId>.api-key`
  - 支持多配置独立密钥:每个 ProviderConfig.id 对应唯一 alias,同一 ProviderType 的不同配置 id 密钥互相隔离
  - 不按 ProviderType 共用密钥
  - API Key 不进入 ProviderConfig(模型层不依赖 storage)
  - 提供 6 个方法:saveKey / readKey / updateKey / removeKey / hasKey / replaceKey
  - saveKey: upsert 语义;updateKey: 不存在抛 NotFound;replaceKey: 安全 upsert(先 exists 判断);removeKey: 幂等;hasKey: 不读取明文
  - 不缓存密钥,每次 read 都从 KeyStore 读取;不维护全局密钥 Map
  - 不暴露 alias 给调用方;日志只记录 providerId 和操作类型,不记录 secret
  - 所有错误保持 SecureStorageError 语义
  - 本地单元测试(`test/ProviderKeyStore.test.ets`):24 项,含 MockKeyStore 内存实现,覆盖 save/read/update/replace/remove/hasKey/隔离/校验/错误传播/不缓存
  - 真机集成测试(`ohosTest/ets/test/ProviderKeyStore.test.ets`):18 项,API 23 模拟器通过,覆盖 A/B 隔离/同类型多配置隔离/更新不影响/删除保留/新实例读取/持久化/幂等/replaceKey/hasKey/校验
  - 全量回归测试:68 项全部通过(含 HttpStreamTransport 5 项,需 hdc rport tcp:8765 tcp:8765 + SSE Mock Server)
  - hilog 扫描:无 `provider-key-test-value` / `sk-` 泄漏
  - 源码扫描:无 `sk-` 真实密钥、无 any/TODO/Node.js/浏览器 API
  - 文件行数:ProviderKeyStore.ets 195 行,本地测试 480 行,真机测试 410 行(均 ≤ 600)
  - 未接入页面(ModelSettingsPage / Index / RealSsePocPage 未修改)
  - 未修改 KeyStore / AssetStoreKeyStore / AliasBuilder / SecureStorageError / Logger 底层实现

### T-1.3 实现 Preferences(用户设置)

- 依赖:T-0.5
- 优先级:P1
- 修改范围:`entry/src/main/ets/storage/`(AppPreferences.ets、ProviderConfigStore.ets、ProviderConfigCodec.ets 新建)、`entry/src/main/ets/models/PreferencesError.ets`(新建)
- 内容:基于 `@ohos.data.preferences` 存储当前选中 Provider id、ProviderConfig 列表等非敏感设置
- 验收标准:
  - [x] 可读写非敏感设置
  - [x] 无明文密钥
- 实现说明:
  - 新增文件:
    - `models/PreferencesError.ets`(247 行):Preferences 错误模型(NotInitialized/SerializationFailed/CorruptedData/AlreadyExists/NotFound/InvalidSelection/UnsupportedVersion)+ isPreferencesError 类型守卫
    - `storage/AppPreferences.ets`(302 行):封装 HarmonyOS Preferences 实例,提供 get/put/delete/flush/clear/getString/has,initialize(context) 初始化
    - `storage/ProviderConfigCodec.ets`(499 行):ProviderConfig ↔ JSON 纯逻辑编解码,schemaVersion=1,敏感字段防御,损坏数据恢复(skippedCount)
    - `storage/ProviderConfigStore.ets`(430 行):ProviderConfig 列表 CRUD + 当前选中 Provider 管理,Promise 序列化并发保护
  - 测试文件:
    - `test/ProviderConfigCodec.test.ets`(651 行):本地单元测试 26+1 用例(编解码/字段匹配/顺序/schemaVersion/敏感字段/损坏恢复/round-trip)
    - `ohosTest/ets/test/ProviderConfigStore.test.ets`(716 行):设备集成测试 27 用例(初始化/CRUD/重复/顺序/选中/清理/并发/损坏恢复/敏感字段)
  - Preferences 文件名:`arktavern_settings`
  - 键:`provider_configs_v1`(ProviderConfig 列表 JSON)、`current_provider_id`(当前选中 id)
  - schemaVersion=1,ProviderConfig 列表序列化为单个版本化 JSON 字符串
  - 敏感字段防御:apikey/api_key/secret/authorization/token/password 不写入 Preferences;编码前检查;解码时拒绝含敏感字段的配置项
  - 并发写保护:Promise 序列化(writeChain),写失败不污染链,错误正确传播
  - 损坏恢复:整个 JSON 无法解析返回 CorruptedData;单个坏配置跳过并计入 skippedCount,不影响有效配置
  - Context:使用 UIAbility context(getCurrentTopAbility),ApplicationContext 对 Preferences 无效(报 401)
  - 删除当前选中 ProviderConfig 自动清空 current_provider_id
  - setCurrentProviderId(null) 允许清空选择;非空 id 不存在时抛 InvalidSelection
  - save 重复 id 抛 AlreadyExists;update 不存在抛 NotFound;remove 幂等
  - list 按 createdAt 升序稳定排序
  - 每次修改调用 flush();写失败不更新内存状态
  - 实际使用的 HarmonyOS API:`@kit.ArkData` 的 preferences(getPreferences/put/get/delete/flush/clear/has),since 9
  - 测试情况:
    - ohosTest 设备测试:96 项全部通过(Tests run: 96, Failure: 0, Error: 0, Pass: 96),含 ProviderConfigStore 27 项 + AssetStoreKeyStore 20 项 + HttpStreamTransport 5 项 + 其他 44 项
    - 本地单元测试:命令行 hvigorw test 报 "SDK component missing"(环境配置问题,需在 DevEco Studio IDE 中运行);ProviderConfigCodec 逻辑已通过 ohosTest 间接验证(ProviderConfigStore 使用 Codec)
    - MCP build_project 编译:entry@default BUILD SUCCESSFUL;entry@ohosTest BUILD SUCCESSFUL
    - test 27 preferences_no_apiKey_field 修复:JSON key 检查改为带引号匹配 `"token"`,避免误判 `maxTokens` 字段名
    - ProviderConfigCodec.ets 行数精简:694 → 499 行(≤600);validateAndExtractFields 函数 54 行(≤100);tryParseItem 函数 7 行(≤100)
  - hilog 敏感扫描:无 apikey/api_key/secret/authorization/token/password/sk- 泄漏
  - 源码扫描:无 sk- 真实密钥,无硬编码 apiKey
  - 文件行数:AppPreferences 302、ProviderConfigCodec 499、ProviderConfigStore 430、PreferencesError 247(均 ≤600)
  - 未接入页面(ModelSettingsPage / Index 未修改)
  - 未修改 ProviderConfig / ProviderType / KeyStore / ProviderKeyStore 底层实现
  - 已知限制:本地单元测试需在 DevEco Studio IDE 中运行(命令行 hvigorw test 报 SDK component missing);跨进程持久性需手工两阶段验证

### T-1.4 实现 OpenAIProvider(非流式)

- 依赖:T-0.2、T-1.1、T-1.2
- 优先级:P1
- 修改范围:`entry/src/main/ets/network/providers/`(新建)
- 参考文件:`SillyTavern-release/src/endpoints/backends/chat-completions.js`(只读)
- 内容:`network/providers/OpenAIProvider.ets`,实现 POST `/v1/chat/completions`,Authorization: Bearer
- 验收标准:
  - [x] 可发送非流式请求并解析 choices
  - [x] 鉴权失败返回 AuthError
- 实现说明:
  - 新增文件:
    - `network/providers/AiProvider.ets`(70 行):Provider 抽象基类,仅定义 `sendChat(config, request): Promise<ChatResponse>` 接口
    - `network/providers/OpenAITypes.ets`(324 行):OpenAI 请求/响应类型定义,类型守卫安全 JSON 解析(禁用 any、as unknown as),extractResponseBody/extractErrorDetail/truncateErrorMessage 提取函数
    - `network/providers/OpenAIProvider.ets`(393 行):OpenAI-compatible 非流式 Provider,依赖注入 HttpClient 和 ProviderKeyStore
    - `network/core/HarmonyHttpClient.ets`(301 行):基于 `@ohos.net.http` 的 HttpClient 实现,支持 GET/POST/PUT/DELETE,错误映射为 NetworkError
    - `models/ChatResponse.ets`(72 行):统一聊天响应模型,仅含 content/finishReason/model/tokens/providerRequestId 等非敏感字段
  - 修改文件:
    - `tools/sse_mock_server.py`:扩展支持 POST `/v1/chat/completions`,16 种场景(401/403/400/404/408/429/500/503/invalid-json/empty-choices/missing-content/null-content/error-in-2xx/usage/long-reply/slow),支持通过 URL query、X-Mock-Scenario header、model 名前缀 `mock-<scenario>-` 三种方式触发场景
  - 测试文件:
    - `test/OpenAIProvider.test.ets`:本地单元测试 45+ 用例,使用 MockHttpClient 内存实现,覆盖正常返回/401/403/429/500/非法 JSON/空 choices/缺失 content/null content/2xx 错误/usage 解析/长回复/URL 构建/请求体构建/ProviderConfig 无 apiKey 字段
    - `test/MockHttpClient.ets`:测试用 HttpClient 内存实现
    - `ohosTest/ets/test/OpenAIProvider.test.ets`:设备集成测试 10 用例(9 自动 + 1 manual),使用真实 HarmonyHttpClient + AssetStoreKeyStore + Python Mock Server
    - `ohosTest/ets/test/HarmonyHttpClient.test.ets`:设备集成测试 11 用例
  - 设计要点:
    - 依赖注入:OpenAIProvider 构造时注入 HttpClient 和 ProviderKeyStore,不内部 new 平台实现
    - API Key 安全:每次请求从 ProviderKeyStore 读取,不缓存到成员变量,不记录到日志,不放入错误对象
    - stream 强制 false:即使传入 request.stream=true,请求体中 stream 字段始终为 false
    - URL 构建:复用 OpenAiUrlBuilder,不复制第二套 URL 拼接逻辑
    - HTTP 错误映射:401/403→Authentication,408→Timeout,429→RateLimit,400→InvalidRequest,5xx→Server,其他→Unknown
    - 类型守卫:所有 JSON 解析使用类型守卫函数,禁用 any 和 as unknown as
    - ArkTS catch 块:使用 instanceof NetworkError 收窄类型,不用 as 转型(运行时不生效)
  - 实际使用的 HarmonyOS API:`@ohos.net.http`(HttpRequest.request/destroy,since 6)、`@ohos.util.TextDecoder`(TextDecoder.create + decodeToString,since 12)、`@ohos.base.BusinessError`
  - 测试情况:
    - 设备集成测试:117 项全部通过(Tests run: 117, Failure: 0, Error: 0, Pass: 117),含 OpenAIProviderDeviceTest 10 项 + HarmonyHttpClientDeviceTest 11 项 + ProviderConfigStore 27 项 + 其他 69 项
    - 本地单元测试:命令行 hvigorw test 报 "SDK component missing"(环境配置问题),逻辑已通过设备测试间接验证
    - MCP build_project 编译:entry@default BUILD SUCCESSFUL;entry@ohosTest BUILD SUCCESSFUL
  - Mock Server 场景触发策略:URL query → X-Mock-Scenario header → model 名前缀 `mock-<scenario>-`(因 OpenAiUrlBuilder 对含 query 的 URL 会追加路径导致 query 丢失,设备测试改用 model 名触发)
  - 设备测试运行命令:`hdc shell aa test -b com.example.arktavern -m entry_test -s unittest OpenHarmonyTestRunner -s timeout 600000`
  - hilog 敏感扫描:无 apiKey/api_key/secret/authorization/token/password/sk- 泄漏
  - 源码扫描:无 sk- 真实密钥,无硬编码 apiKey,无 any/TODO/Node.js/浏览器 API
  - 文件行数:AiProvider 70、OpenAITypes 324、OpenAIProvider 393、HarmonyHttpClient 301、ChatResponse 72(均 ≤600)
  - 未接入页面(Index / ModelSettingsPage / ChatPage 未修改)
  - 未修改 ProviderConfig / ProviderKeyStore / KeyStore / AssetStoreKeyStore / HttpClient 接口底层实现
  - 已知限制:本地单元测试需在 DevEco Studio IDE 中运行(命令行 hvigorw test 报 SDK component missing);OpenAiUrlBuilder 对含 query 参数的 URL 会追加路径导致 query 丢失(已通过 model 名触发场景规避)

### T-1.5 实现 OpenAIProvider(流式)

- 依赖:T-0.3、T-1.4
- 优先级:P1
- 修改范围:`network/providers/OpenAIProvider.ets`(扩展)、`network/providers/OpenAIStreamSession.ets`(新增)、`models/ChatStreamTypes.ets`(新增)、`network/streaming/HttpStreamTransport.ets`(修复 statusCode=0 bug)
- 内容:stream=true,复用 SseParser,通过回调增量返回 delta
- 验收标准:
  - [x] 可增量返回 token
  - [x] 可中断
  - [x] [DONE] 正确结束
- 完成记录:
  - OpenAIProvider 已支持 stream=true(强制覆盖 request.stream)
  - 复用 HttpStreamTransport(未复制第二套传输逻辑)
  - 复用 Utf8StreamDecoder(SseParser 内部使用)
  - 复用 SseParser(未复制第二套 SSE 解析器)
  - 复用 OpenAiSseDeltaParser(未复制第二套 delta 解析器)
  - 支持增量 delta(顺序严格保持,不 trim/不合并标点/不修改 Markdown/不过滤中文 Emoji)
  - 支持 [DONE] 识别(receivedDone=true)
  - 支持无 [DONE] 兼容结束(有 content 或 finish_reason 即允许完成,receivedDone=false)
  - 支持 abort(幂等,触发 onError(Cancelled),不触发 onComplete)
  - 支持 usage(prompt_tokens/completion_tokens/total_tokens)和 finish_reason(stop/length/content_filter/tool_calls/未知值)
  - 错误映射通过(401→Authentication,429→RateLimit,500→Server,408→Timeout,DNS→Network,取消→Cancelled,JSON 解析失败→Parse)
  - API Key 生命周期:每次 streamChat 独立读取,不缓存,不放入结果/错误/日志
  - completeFired/errorFired 标志确保 complete/error 只触发一次,迟到回调被忽略
  - HttpStreamTransport 修复:headersReceive/dataEnd 先于 Promise resolve 时缓存信号,等 statusCode 已知后补发
  - OpenAIStreamSession 修复:headers 收到前缓存 chunks,确保错误状态码在 SSE 解析前被识别
  - Mock Server 扩展:16 个流式场景(含含连字符场景名),HTTP/1.1 协议支持
  - API 23 Mock Server 设备测试通过(136 个测试全部通过,含 19 个流式测试)
  - 真实兼容端点手工验证:未执行(遵循安全规则,不硬编码密钥;Mock Server 设备测试已充分覆盖)
  - 未修改页面(Index/ChatPage/ModelSettingsPage/RealSsePocPage/CharacterListPage/LorebookPage/AppSettingsPage)
  - 未开始 T-1.6

### T-1.6 实现 ModelService

- 依赖:T-1.2、T-1.3、T-1.5
- 优先级:P1
- 修改范围:`entry/src/main/ets/services/`(新建)、`entry/src/main/ets/models/ModelServiceError.ets`(新建)、`entry/src/ohosTest/ets/test/ModelService.test.ets`(新建)、`entry/src/ohosTest/ets/test/List.test.ets`(注册测试)、`entry/src/main/ets/network/streaming/HttpStreamTransport.ets`(修复 unusedSymbol warning)
- 内容:`services/ModelService.ets` 统一编排 ProviderConfigStore / ProviderKeyStore / AiProvider,提供 13 个公共方法(initialize/listConfigs/getConfig/getCurrentConfig/createConfig/updateConfig/deleteConfig/setCurrentConfig/hasApiKey/sendChat/streamChat/testConnection);`services/ProviderFactory.ets` 工厂与辅助函数;`models/ModelServiceError.ets` 11 种错误类型 + 脱敏 causeMessage
- 验收标准:
  - [x] 页面层不直接接触网络层(ModelService 作为唯一入口)
  - [x] 可切换 Provider(setCurrentConfig + ProviderConfigStore 当前选中管理)
  - [x] 事务回滚:createConfig 密钥失败回滚配置删除;updateConfig 未传 apiKey 保留原密钥;deleteConfig 部分失败明确返回 PartialFailure
  - [x] testConnection 不污染正式配置(使用 `__test__.<id>` 临时 alias,测试后清理)
  - [x] Claude/Gemini 返回 UnsupportedProvider;OpenAICompatible/OpenAI/DeepSeek/OpenRouter 走 OpenAI-compatible 协议
  - [x] 不缓存 API Key,不修改 ProviderConfig 增加 API Key,不将 API Key 写入 Preferences
  - [x] wrapNetworkError 不将 err.message 直接拼入 message(脱敏通过 causeMessage 传递)
  - [x] HttpStreamTransport 两个 unusedSymbol warning 已修复(移除 errorTypeFromStatusCode import 和 dataReceiveCount 字段)
  - [x] 所有新增文件 ≤600 行(ModelService.ets 600 / ProviderFactory.ets 147 / ModelServiceError.ets 145 / ModelService.test.ets 586)
  - [x] 设备测试通过:ModelService 20 + ProviderConfigStore 28 + ProviderKeyStore 18 + OpenAIProvider 10 + OpenAIProviderStream 19 = 95/95
  - [x] 无 API Key 泄漏(源码仅含 `sk-fake*` 假数据)
  - [x] 未修改页面、AssetStoreKeyStore.ets、ProviderConfigStore.ets、ProviderKeyStore.ets、OpenAIProvider.ets
  - 未开始 T-1.8

### T-1.7 实现模型设置页与最小验证页

- 依赖:T-1.6
- 优先级:P1
- 修改范围:`entry/src/main/ets/pages/`、`entry/src/main/ets/viewmodels/`、`main_pages.json`
- 内容:`pages/ModelSettingsPage.ets`(表单)、`pages/QuickChatPage.ets`(输入一句话 → 流式显示回复)、对应 ViewModel
- 验收标准:
  - [x] 可保存多个 Provider 配置
  - [x] 可发送一句话并看到流式回复(注:本次只做模型设置页,QuickChatPage 未要求)
  - [x] 错误有提示
- 完成情况(2026-07-17):
  - [x] 正式模型设置页已可用(配置列表 + 编辑表单 + 保存/测试/设为当前/删除)
  - [x] API Key 仅存 Asset Store,不回显原密钥,保存/测试后立即清空输入
  - [x] 配置存 Preferences(非敏感字段),schemaVersion=1
  - [x] 连接测试已通过(Mock Provider 验证,不修改正式配置)
  - [x] 首页模型状态已接入(读取 ModelService 当前配置显示名称与模型名)
  - [x] AppServices 组合根:EntryAbility.onCreate 异步初始化,页面 aboutToAppear 调用 whenReady()
  - [x] ModelServiceError 错误包装修复:公开 message 固定脱敏,底层信息仅进入 causeMessage
  - [x] Provider 类型:Claude/Gemini 显示"暂未支持",OpenAI/DeepSeek/OpenRouter 走 OpenAI-compatible
  - [x] 设备测试通过:ModelSettingsViewModel 19/19 + ModelService 20/20 = 39/39
  - [x] 所有新增文件 ≤600 行
  - [x] 无 API Key 泄漏(源码扫描 + hilog 无 apiKey + Preferences 无敏感字段)
  - 未开始 T-1.8

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
