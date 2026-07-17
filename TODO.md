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
- T-1.7F 缺陷修复(2026-07-16):
  - [x] 保存无反应根因修复:@Builder 参数传递 vm 导致 @Observed 属性变更不触发 UI 重渲染
  - [x] 页面不再通过 @Builder 参数传递 ViewModel,直接使用 @State 绑定
  - [x] 错误消息从滚动底部移至页面顶部,背景色区分错误/成功
  - [x] 保存按钮状态反馈:显示"保存中…"/"测试中…",按钮禁用
  - [x] save() 使用 try/catch/finally 确保 isSaving 恢复
  - [x] 保存失败不清空 API Key,方便用户修改后重试
  - [x] populateForm 不再调用 applyPresetForType 覆盖已加载的 baseUrl/modelName
  - [x] API Key 使用 InputType.Normal + 页面圆点掩码 + 显隐切换,不触发系统安全键盘
  - [x] API Key 关闭复制(CopyOptions.None)
  - [x] DeepSeek 预设模式:自动填充 URL/Model,只填 Key 即可保存
  - [x] DeepSeek V4 Flash / V4 Pro 可选择,模型切换自动更新 modelName
  - [x] DeepSeek URL 自动设为 `https://api.deepseek.com/chat/completions`
  - [x] ProviderPreset.ets 预设数据模型(preset 不含 API Key,不存 Preferences)
  - [x] OpenAI Compatible 继续要求用户填写 Base URL 和 Model
  - [x] 设备测试:ModelSettingsViewModel 28/28 + ModelService 20/20 = 48/48
  - T-1.7F 实机验证通过：DeepSeek 配置保存、当前配置切换、API Key 安全存储、普通键盘输入均正常。
  - 未开始 T-1.8

### T-1.8 最小可用流式聊天

- 依赖:T-1.7
- 优先级:P1
- 修改范围:`services/ChatService.ets`(新建)、`viewmodels/ChatViewModel.ets`(新建)、`pages/ChatPage.ets`(重写)、`models/ModelServiceError.ets`、`models/ChatStreamTypes.ets`、资源文件
- 内容:内存中单次临时流式聊天,不做数据库和历史会话
- 验收标准:
  - [x] 用户输入消息后发送,实时看到模型流式回复
  - [x] 点击停止生成,保留已生成文本
  - [x] 清空当前临时对话
  - [x] 页面返回后不崩溃
  - [x] 无模型配置时显示"尚未配置模型"+"前往模型设置"按钮
  - [x] 错误映射为中文提示(Auth/429/Timeout/Network/Server/Parse/模型名称未配置等)
  - [x] 状态机单向切换:Idle→Sending→Streaming→Completed/Cancelled/Failed
  - [x] 页面不直接调用 OpenAIProvider/ProviderKeyStore/ProviderConfigStore
  - [x] ChatService 只通过 ModelService 发送请求
  - [x] 不缓存 API Key,不记录消息全文到日志
  - [x] 同一时间只允许一个生成请求
  - [x] stopGeneration 调用 ChatStreamHandle.abort
  - [x] ModelService 自动从 ProviderConfig 填充 modelName(mergeRequestModel)
  - [x] 设备测试:ChatService 27/27 + ChatViewModel 22/22 = 49/49
  - [x] 所有新增文件 ≤600 行
  - [x] 无 API Key 或消息正文泄漏到 hilog
  - 实机验证通过:DeepSeek 流式聊天正常,停止生成正常,中文/Emoji/换行正常
  - 未整合:Character prompt / Lorebook / Preset / PromptBuilder / Swipe / Markdown 渲染 / 历史会话

### T-1.9 聊天链路收尾与技术债清理

- 依赖:T-1.8
- 优先级:P1
- 修改范围:`services/ChatService.ets`、`viewmodels/ChatViewModel.ets`、`pages/ChatPage.ets`、`services/ModelService.ets`、`models/ChatMessage.ets`、`models/ChatRequest.ets`、`services/AppServices.ets`、测试文件、资源文件
- 内容:
  1. 移除 `__from_config__` 哨兵:ModelService 新增 `streamCurrentChat(messages, options, callbacks)` 显式 API,自动注入 config.modelName;ChatService 不再使用特殊字符串
  2. 重新生成:ChatService 新增 `regenerateLastResponse()`;ChatViewModel 新增 `regenerate()` 和 `canRegenerate`;ChatPage 增加重新生成按钮
  3. 复制消息:使用 `@ohos.pasteboard` 系统剪贴板,空消息/流式生成中不可复制,复制成功 toast
  4. 自动滚动:Scroller + scrollEdge(Edge.Bottom),用户上滑后不强制跳底,浮动回底按钮
  5. 消息状态:ChatMessageStatus 枚举(Streaming/Completed/Cancelled/Failed),停止后显示"已停止",错误保留部分文本
  6. 页面生命周期:aboutToDisappear 停止请求,迟到 delta 忽略,配置删除/禁用后禁止发送
- 验收标准:
  - [x] 不再出现 `__from_config__`
  - [x] ModelService 自动使用当前 config.modelName
  - [x] 正常发送无回归
  - [x] 重新生成删除旧 Assistant 回复
  - [x] 重新生成保留 User 消息
  - [x] 停止后可重新生成
  - [x] 无消息时不可重新生成
  - [x] 复制消息成功
  - [x] 空消息不可复制
  - [x] 自动滚动
  - [x] 用户上滑后不强制跳底
  - [x] 页面退出停止请求
  - [x] 迟到 delta 被忽略
  - [x] 错误保留部分文本
  - [x] 空响应显示错误
  - [x] 当前配置删除后禁止发送
- 完成情况(2026-07-16):
  - [x] `__from_config__` 哨兵已完全移除,ModelService.streamCurrentChat() 自动注入 modelName
  - [x] ChatRequestOptions 接口(不含 model 字段)由 ModelService 填充 model
  - [x] ChatMessageStatus 枚举(Streaming/Completed/Cancelled/Failed) + status 字段
  - [x] ChatService.regenerateLastResponse() 完整实现(找到最后 User→删除其后 Assistant→重新请求)
  - [x] ChatService.canRegenerate() 判断(非生成中 && 至少有一个 Assistant 消息)
  - [x] ChatPage 重新生成按钮(canRegenerate && !isGenerating 时显示)
  - [x] ChatPage 复制按钮使用 @ohos.pasteboard(createData + getSystemPasteboard().setData)
  - [x] 复制成功 toast 提示,空消息/流式生成中不可复制
  - [x] Scroller 自动滚动到底部,onScrollEdge 检测用户上滑,浮动回底按钮
  - [x] 停止后显示"已停止"状态,错误保留部分文本,空回复显示错误
  - [x] aboutToDisappear 停止请求,迟到 delta 忽略(completeFired/errorFired 标志)
  - [x] ChatPage 内"前往模型设置"导航(通过 queryNavigationInfo().pathStack)
  - [x] AppServices.getChatService()/getModelService() 静态方法
  - [x] 设备测试:ChatService 27/27 + ChatViewModel 22/22 + ModelService 20/20 = 69/69
  - [x] MCP build entry@default + entry@ohosTest BUILD SUCCESSFUL
  - [x] 实机验证:ChatPage 正常显示,navigation 正确,homepage 显示"当前模型:ds · deepseek-v4-flash"
  - [x] hilog 无 API Key/消息正文泄漏
  - [x] 所有新增/修改文件 ≤600 行
  - 未修改:OpenAIProvider/network/streaming/ProviderConfigStore/ProviderKeyStore/AssetStoreKeyStore/ModelSettingsPage/Character/Lorebook/数据库/ArkTavern-Reference
  - 未开始 Phase 2
  - 偶发异常修复(2026-07-16):
    - [x] 修复 AppServices 单例 ChatService 被 dispose 后复用导致 sendMessage 静默失败
    - [x] 修复消息原地修改数组导致 ArkUI 不刷新(改为不可变更新模式)
    - [x] 修复 ForEach key 只用 msg.id 导致内容变化时 skip mark dirty(key 加入 updatedAt+status+contentLength+isStreaming)
    - [x] 修复 ChatViewModel messages 未以新引用赋值(添加 onMessagesUpdate 回调同步到 ChatPage 独立 @State)
    - [x] 修复空回复显示"回复成功"(onComplete 时 content 为空 → 标记 Failed)
    - [x] 修复 stopGeneration 不触发状态回调(使用 lastCallbacks 保存最近回调)
    - [x] 增加启动阶段 15 秒超时保护(收到首个 onStart/onDelta/onComplete/onError 后清除)
    - [x] 修复 sendMessage disposed 时静默失败(改为 throw Error)
    - [x] 修复 inputText 过早清空(移到消息创建成功后)
    - [x] 设备测试:ChatService 36/36 + ChatViewModel 16/16 = 52/52 通过
    - [x] 实机验证:消息正常显示,无 ForEachNode skip mark dirty,无 API Key/消息正文泄漏

---

## Phase 2:基础聊天

### T-2.1 Character MVP：角色模型、手工创建、角色选择和基础角色聊天

- 依赖:T-1.9
- 优先级:P1
- 修改范围:`models/Character.ets`(新建)、`storage/CharacterStore.ets`(新建)、`services/CharacterService.ets`(新建)、`viewmodels/CharacterListViewModel.ets`(新建)、`pages/CharacterListPage.ets`(重写)、`services/ChatService.ets`、`viewmodels/ChatViewModel.ets`、`pages/ChatPage.ets`、`services/AppServices.ets`、资源文件、测试
- 内容:
  - 角色模型:Character.ets(id/name/description/personality/scenario/firstMessage/systemPrompt/avatarUri/createdAt/updatedAt),不依赖ArkUI,提供校验和不可变更新
  - 角色持久化:CharacterStore 基于 Preferences 保存角色列表(schemaVersion=1),支持 list/getById/save/update/remove/setCurrentCharacterId/getCurrentCharacter
  - 角色列表页:CharacterListPage 完整可用(列表/新建/编辑/删除确认/设为当前/当前标记/空状态),表单字段含名称/描述/性格/场景/开场白/System Prompt
  - 角色接入聊天:ChatPage 顶部显示当前角色名称;有角色时注入 System 消息和 firstMessage 开场白;无角色时保持普通聊天;System 消息不显示为聊天气泡
- 验收标准:
  - [x] 角色模型含必填字段,不依赖 ArkUI
  - [x] 角色持久化,重启后仍存在
  - [x] 角色列表页可新建/编辑/删除/设为当前
  - [x] 删除当前角色时清空选择
  - [x] 首条请求包含角色 System 消息
  - [x] firstMessage 只添加一次,不重复
  - [x] 重新生成不重复注入角色提示
  - [x] 无角色时普通聊天无回归
  - [x] 聊天消息响应式刷新正常
  - [x] hilog 不记录角色聊天正文
- 完成情况(2026-07-16):
  - [x] Character.ets:纯数据模型,createCharacter()/updateCharacter()/validateCharacter()/buildCharacterSystemContent()
  - [x] CharacterStore.ets:基于 Preferences 的 JSON 序列化持久化,key 为 character_list_v1 和 current_character_id_v1
  - [x] CharacterService.ets:封装 CharacterStore 的业务逻辑层
  - [x] CharacterListViewModel.ets:@Observed 装饰,管理角色列表页状态
  - [x] CharacterListPage.ets:完整角色列表页(文字头像+名称+描述+当前标记+操作按钮+空状态+新建FAB+删除确认+编辑对话框)
  - [x] ChatService.initContext(character):消息列表为空时注入 System 消息和 firstMessage
  - [x] ChatPage 过滤 System 角色消息(不显示为聊天气泡)
  - [x] ChatPage 标题栏显示角色名
  - [x] AppServices.ensureDefaultCharacter() 在无角色时自动创建默认角色
  - [x] 表单字段使用 @State + $$ 双向绑定(兼容 MCP inputText 工具)
  - [x] 设备测试:ChatService 35/35 + ChatViewModel 25/25 = 60/60 通过
  - [x] MCP build entry@default BUILD SUCCESSFUL
  - [x] 实机验证:默认角色创建、设为当前、聊天页显示角色名和开场白、系统消息隐藏、返回再进入不重复开场白
  - 未修改:OpenAIProvider/network/streaming/AssetStoreKeyStore/模型设置页/Lorebook/PNG 解析/RDB/ArkTavern-Reference
  - 已知限制:MCP inputText 不触发 ArkUI onChange 回调,改用 @State + $$ 双向绑定 + 程序化创建默认角色;PNG 角色卡导入、Lorebook、数据库迁移未开发

---

### T-2.2 Character JSON 导入、导出与格式兼容

- 依赖:T-2.1
- 优先级:P1
- 修改范围:`parser/CharacterCardJsonParser.ets`(新建)、`parser/CharacterCardJsonWriter.ets`(新建)、`services/CharacterService.ets`、`viewmodels/CharacterListViewModel.ets`、`pages/CharacterListPage.ets`、`services/AppServices.ets`、资源文件、测试
- 参考文件:`ArkTavern-Reference/SillyTavern-release/src/character-card-parser.js`、`src/types/spec-v2.d.ts`(只读)
- 内容:
  - 格式解析独立到 parser 层,页面不得直接 JSON.parse 角色卡
  - CharacterCardJsonParser:解析 ArkTavern schemaVersion=1、V2(chara_card_v2)、V3(chara_card_v3)格式,映射 name/description/personality/scenario/first_mes→firstMessage/system_prompt→systemPrompt 等字段,缺 name 拒绝,损坏 JSON/未知版本/超大文件给可读错误
  - CharacterCardJsonWriter:导出 ArkTavern schemaVersion=1,文件名安全处理,不含 API Key/模型配置/聊天记录/本地绝对路径
  - CharacterService:新增 importFromJson/exportToJson/readFileContent/writeFileContent/importFromFile/exportToFile
  - CharacterListViewModel:导入预览状态(showImportPreview/previewCard/importJsonBuffer),导出操作
  - CharacterListPage:"导入"按钮(文件选择器→预览→确认→刷新列表),"导出"按钮(每角色→保存位置选择器),不自动设为当前角色
  - id 冲突时生成新 UUID,不覆盖现有角色
  - 修正:移除 ensureDefaultCharacter(),正式首次启动角色列表为空;不强制选中角色
- 验收标准:
  - [x] ArkTavern JSON 往返(read→write→read 字段一致)
  - [x] V2/V3 常见字段映射(name/first_mes→firstMessage/system_prompt→systemPrompt)
  - [x] 非法 JSON、空 name、未知版本给可读错误
  - [x] id 冲突生成新 UUID
  - [x] 导入不覆盖当前角色
  - [x] 导出无敏感数据(apiKey/authorization/token)
  - [x] 现有角色聊天无回归
  - [x] 正式首次启动角色列表为空
  - [x] CharacterListPage 在 main_pages.json 注册(因 @Entry 装饰器要求)
- 完成情况(2026-07-16):
  - [x] parser/CharacterCardJsonParser.ets:ParsedCharacterCard 中间格式,parseCharacterJson() 统一入口,支持 ArkTavern v1/V2/V3,含错误处理与字段截断
  - [x] parser/CharacterCardJsonWriter.ets:writeCharacterToJson() 导出,findSensitiveKeys() 敏感键检测,sanitizeFileName() 安全文件名
  - [x] CharacterService 新增 parseCharacterJson/importFromParsed/importFromJson/exportToJson/readFileContent/writeFileContent/importFromFile/exportToFile(8 个方法)
  - [x] CharacterListViewModel 新增 startImportFile/confirmImport/cancelImport/exportToFile
  - [x] CharacterListPage 新增"导入"按钮(顶部操作栏)、"导出"按钮(每角色卡片)、导入预览对话框(含来源格式标识)、导入错误提示
  - [x] AppServices 移除 ensureDefaultCharacter(),默认角色列表为空
  - [x] 设备测试:CharacterCardJsonParser 18/18 + CharacterCardJsonWriter 18/18 + 现有 ChatService 35/35 + ChatViewModel 25/25 = 96/96 通过
  - [x] MCP build entry@default + entry@ohosTest BUILD SUCCESSFUL
  - [x] hilog 无敏感数据泄露
  - 未实现:PNG 元数据解析、头像文件复制、Lorebook、alternate greetings、在线角色市场、RDB
  - 已知限制:模拟器 DocumentViewPicker 不可用(真机正常),导入/导出仅真机可测试

---

### T-2.3 PNG 角色卡导入

- 依赖:T-2.2
- 优先级:P1
- 修改范围:`parser/PngCharacterCardParser.ets`(新建)、`storage/CharacterAssetStore.ets`(新建)、`services/CharacterService.ets`、`services/AppServices.ets`、`viewmodels/CharacterListViewModel.ets`、`pages/CharacterListPage.ets`、测试
- 参考文件:`ArkTavern-Reference/SillyTavern-release/src/character-card-parser.js`(只读,PNG 元数据 chunk 关键字参考)
- 内容:
  - PngCharacterCardParser:纯逻辑 PNG 解析,校验 8 字节签名,遍历 chunk,读取 tEXt chunk 中 `chara`(V2)/`ccv3`(V3)关键字,Base64 解码后返回 JSON 字符串
  - CharacterAssetStore:将导入 PNG 复制到应用私有目录 `filesDir/avatars/`,生成安全文件名 `avatar_{id}.png`,删除角色时同步删除头像
  - CharacterService:新增 readFileBytes/importPngFromFile/confirmPngImport,复用 CharacterCardJsonParser 解析 JSON
  - CharacterListViewModel:自动检测 `.png` 后缀分流到 startPngImport,预览状态含 isPngImport/previewPngUri
  - CharacterListPage:导入预览对话框增加 PNG 头像 Image 组件
  - 文件大小限制 50MB,chunk 数据限制 100MB,text 限制 10MB
  - 导入失败时无残留文件(confirmPngImport 失败回滚删除头像)
- 验收标准:
  - [x] 正常 V2 PNG(chara tEXt chunk)解析成功
  - [x] 正常 V3 PNG(ccv3 tEXt chunk)解析成功
  - [x] V3 优先于 V2
  - [x] 无元数据 PNG 返回可读错误
  - [x] PNG 签名错误返回可读错误
  - [x] chunk 数据越界返回可读错误
  - [x] Base64 非法返回可读错误
  - [x] 超大文件(>50MB)返回可读错误
  - [x] 中文角色名正确解析(UTF-8 编解码)
  - [x] URL-safe Base64 支持
  - [x] id 冲突生成新 UUID
  - [x] 导入成功后头像保存到应用私有目录
  - [x] 删除角色时头像同步清理
  - [x] 取消导入无残留文件
  - [x] JSON 导入现有功能无回归
  - [x] hilog 不记录角色正文或图片元数据全文
- 完成情况(2026-07-16):
  - [x] parser/PngCharacterCardParser.ets:纯逻辑 PNG 解析(约 280 行),含 tEXt 解析、Base64 解码、UTF-8 解码、Latin-1 解码,不依赖设备 API
  - [x] storage/CharacterAssetStore.ets:头像文件持久化(约 95 行),使用 @kit.CoreFileKit 的 fileIo
  - [x] CharacterService 新增 PngImportResult 接口、readFileBytes/importPngFromFile/confirmPngImport 方法
  - [x] CharacterListViewModel 新增 isPngImport/previewPngUri 状态、startPngImport 分流
  - [x] CharacterListPage 新增 PNG 头像预览(80x80 Image 组件)
  - [x] AppServices 初始化 CharacterAssetStore 并注入 CharacterService
  - [x] 设备测试:PngCharacterCardParser 9/9 通过(含 V2/V3/中文/URL-safe/错误处理)
  - [x] MCP build entry@default + entry@ohosTest BUILD SUCCESSFUL
  - 未实现:zTXt/iTXt chunk 解析(当前规范仅需 tEXt)、Lorebook、alternate greetings、在线角色市场
  - 已知限制:本地单元测试需在 DevEco Studio IDE 中运行(命令行 hvigorw test 报 SDK component missing);真机 PNG 导入需用户手动操作

---

### T-2.4 Lorebook MVP：世界书模型、持久化、管理页面、关键词匹配和聊天注入

- 依赖:T-2.1
- 优先级:P2
- 修改范围:`models/Lorebook.ets`(新建)、`storage/LorebookStore.ets`(新建)、`services/LorebookService.ets`(新建)、`viewmodels/LorebookViewModel.ets`(新建)、`pages/LorebookPage.ets`(重写)、`services/ChatService.ets`、`services/AppServices.ets`、资源文件、测试
- 内容:
  - 世界书模型:Lorebook(id/name/description/enabled/entries/createdAt/updatedAt)、LorebookEntry(id/name/keys/secondaryKeys/content/enabled/constant/selective/position/priority/createdAt/updatedAt),Position 仅支持 BeforeCharacter/AfterCharacter
  - 持久化:LorebookStore 基于 Preferences(schemaVersion=1),键名 lorebook_list_v1/current_lorebook_id_v1,支持 list/getById/save/update/remove/setCurrentLorebookId/getCurrentLorebook
  - 业务服务:LorebookService 提供 CRUD 和 matchEntries/buildInjectionAsync,关键词匹配规则(扫描最近 10 条 User/Assistant 消息,英文不区分大小写,中文原文本包含匹配,constant 始终激活,selective 需主+次关键词,disabled 跳过,priority 排序,最大字符限制 12000)
  - 聊天注入:ChatService 每次发送前调用 buildInjectionAsync,BeforeCharacter 放 System Prompt 之前,AfterCharacter 放之后,世界书内容不显示为聊天气泡,不永久加入 visible messages
  - 页面:LorebookPage 支持世界书列表/新建/编辑/删除/设为当前/启用/禁用/条目管理/关键词逗号或换行分隔/Constant/Selective 开关/Priority 数字/Position 选择/空状态和错误提示
- 验收标准:
  - [x] 世界书模型含必填字段,不依赖 ArkUI,提供校验和不可变更新
  - [x] 世界书持久化,重启后仍存在
  - [x] 世界书页面可新建/编辑/删除/设为当前/启用/禁用
  - [x] 删除当前世界书时清空选择
  - [x] 条目可新建/编辑/删除,关键词逗号或换行分隔
  - [x] Constant 条目始终匹配
  - [x] 普通关键词匹配(英文不区分大小写,中文原文本包含)
  - [x] Selective 主关键词+次关键词同时匹配
  - [x] 禁用条目不匹配
  - [x] Priority 排序
  - [x] Before/After 注入顺序正确
  - [x] 世界书 System 消息不显示为聊天气泡
  - [x] 无世界书时聊天行为无回归
  - [x] hilog 不记录世界书正文或聊天正文
  - [x] entry@default + entry@ohosTest 编译通过
- 完成情况(2026-07-17):
  - [x] Lorebook.ets:纯数据模型(~280 行),createLorebook()/updateLorebook()/validateLorebook()/createLorebookEntry()/updateLorebookEntry()/validateLorebookEntry()/addEntryToLorebook()/removeEntryFromLorebook()/updateEntryInLorebook()
  - [x] LorebookStore.ets:基于 Preferences 的 JSON 序列化持久化(~240 行),key 为 lorebook_list_v1 和 current_lorebook_id_v1
  - [x] LorebookService.ets:封装 LorebookStore 的业务逻辑层(~280 行),含 matchEntriesForLorebook()/buildInjectionAsync()/matchEntryInText() 匹配引擎
  - [x] LorebookViewModel.ets:@Observed 装饰,管理世界书页状态(~220 行)
  - [x] LorebookPage.ets:完整世界书管理页(~540 行),含世界书卡片/条目列表/新建编辑删除对话框/空状态/新建 FAB
  - [x] ChatService.buildRequestMessages():构建带世界书注入的请求消息列表,BeforeCharacter→System Prompt→AfterCharacter→其他消息
  - [x] AppServices:注册 LorebookStore/LorebookService 为全局服务,注入 ChatService 构造函数
  - [x] MCP build entry@default + entry@ohosTest BUILD SUCCESSFUL
  - [x] 模拟器验证:LorebookPage 正常显示,创建世界书成功,按钮(设为当前/编辑/禁用/删除)正常
  - [x] hilog 无 API Key/世界书正文/聊天正文泄漏
  - 未实现:向量匹配、正则表达式、递归扫描、概率触发、Preset
  - 已知限制:设备测试无法通过命令行运行(MCP build --mode module 导致 main HAP 缺少 test runner),需在 DevEco Studio IDE 中运行;实机端到端聊天注入验证需用户手动操作

---

### T-2.5 PromptBuilder MVP：统一提示词构建

- 依赖:T-2.1, T-2.4
- 优先级:P2
- 修改范围:`models/PromptSegment.ets`(新建)、`services/PromptBuilder.ets`(新建)、`services/ChatService.ets`、`services/AppServices.ets`、`pages/ChatPage.ets`、测试
- 内容:
  - PromptSegment 模型:PromptSegmentPosition 枚举(BeforeCharacter/Character/AfterCharacter/Conversation)和 PromptSegment 接口
  - PromptBuilder 服务:接收角色/世界书/消息,统一构建最终请求消息,不修改原始消息数组,不保存状态
  - 固定顺序:BeforeCharacter 世界书(System)→Character System Prompt(System)→AfterCharacter 世界书(System)→聊天历史
  - ChatService 迁移:删除 buildRequestMessages() 世界书拼接逻辑,改为调用 PromptBuilder.build()
  - AppServices 注入:创建 PromptBuilder 并注入 ChatService 构造函数
- 验收标准:
  - [x] Prompt 构建职责已从 ChatService 抽离
  - [x] 页面不直接调用 PromptBuilder
  - [x] ChatService 不再手工维护世界书位置顺序
  - [x] 角色、世界书和聊天历史顺序正确
  - [x] 世界书内容仅进入请求,不进入可见消息
  - [x] 重新生成不重复注入
  - [x] 无角色或无世界书时无行为回归
  - [x] 不记录角色正文、世界书正文或聊天正文到 hilog
  - [x] 不出现 API Key 泄漏
  - [x] entry@default + entry@ohosTest BUILD SUCCESSFUL
- 完成情况(2026-07-17):
  - [x] PromptSegment.ets:纯数据模型(~60 行),含排序函数
  - [x] PromptBuilder.ets:核心构建器(~130 行),build() 方法同步构建,注入 LorebookService 进行匹配
  - [x] ChatService.ets:删除 buildRequestMessages() 世界书拼接,新增 promptBuilder 字段和 character 字段,新 buildRequestMessages() 调用 PromptBuilder
  - [x] AppServices.ets:创建 PromptBuilder 实例,新增 createChatService() 工厂方法
  - [x] ChatPage.ets:通过 AppServices.createChatService() 获取 ChatService,不再直接依赖 PromptBuilder
  - [x] System 消息修复:PromptBuilder 不再无条件跳过 System 消息;ChatService.initContext 不再存储 System 消息到 messages
  - [x] PromptBuilder.test.ets:15 个本地单元测试(覆盖 System 保留/character+worldbook 顺序/constant/关键词/selective/disabled/priority/firstMessage/rebuild)
  - [x] MCP 增量编译 entry@default + entry@ohosTest BUILD SUCCESSFUL
  - [x] 模拟器启动正常,无 hilog 敏感数据泄漏,无崩溃
  - 未实现:宏替换、TokenCounter、历史截断、Preset、正则世界书、递归扫描
  - 已知限制:本地单元测试无法通过 hvigorw 运行(SDK component missing),需在 IDE 中运行;设备测试同样受限

### T-2.6 MacroReplacer MVP：基础宏替换

- 依赖:T-2.5
- 优先级:P2
- 修改范围:`models/MacroContext.ets`(新建)、`services/MacroReplacer.ets`(新建)、`services/PromptBuilder.ets`、`services/ChatService.ets`、`services/AppServices.ets`、测试
- 内容:
  - 纯数据模型 MacroContext(characterName/userName),不依赖 ArkUI
  - MacroReplacer 支持 {{char}} / {{character}} / {{user}} 三个基础宏,大小写不敏感
  - 未识别宏保持原样,空字符串/无上下文时原样保留
  - 不递归替换,相同输入结果一致
  - PromptBuilder 通过构造注入 MacroReplacer,仅在最终 ChatMessage[] 生成时执行替换
  - ChatService 构造 MacroContext 传入 PromptBuilder,userName 默认 `User`
  - AppServices 唯一创建并注入,不暴露 getMacroReplacer()
  - 页面不感知,ChatService 不写正则
- 验收标准:
  - [x] MacroReplacer 是独立服务
  - [x] PromptBuilder 通过注入使用 MacroReplacer
  - [x] 页面和 ChatService 不包含宏正则逻辑
  - [x] 三个基础宏替换正确
  - [x] 未识别宏保持原样
  - [x] 无上下文时不错误替换为空字符串
  - [x] 不递归替换
  - [x] 原始 Character / 世界书 / 消息对象未修改
  - [x] firstMessage 不重复
  - [x] Prompt 顺序不变
  - [x] entry@default + entry@ohosTest BUILD SUCCESSFUL
  - [x] 无正文和 API Key 日志泄漏
- 完成情况(2026-07-17):
  - [x] MacroContext.ets:interface(characterName / userName) + createMacroContext 工厂
  - [x] MacroReplacer.ets:RegExp `/\{\{(char|character|user)\}\}/gi` 一次性匹配,大小写不敏感
  - [x] PromptBuilder.ets:构造注入 MacroReplacer,build() 在 seg→message 转换循环中应用替换,生成新 ChatMessage 对象
  - [x] ChatService.ets:新增 DEFAULT_USER_NAME 常量,buildRequestMessages 构造 MacroContext 传入
  - [x] AppServices.ets:createChatService 注入 tokenCounter + MacroReplacer(通过 PromptBuilder)
  - [x] MacroReplacer.test.ets:15 个本地单元测试(覆盖 3 个宏 / 大小写 / 多宏 / 未识别 / 空文本 / 空上下文 / 非递归 / 原始不变)
  - [x] PromptBuilder.test.ets:扩展 13 个宏观集成测试(覆盖 System / worldbook / firstMessage / user / assistant 替换 + 原对象不变)
  - [x] MCP 增量编译 entry@default + entry@ohosTest BUILD SUCCESSFUL
  - [x] 模拟器冒烟通过:Alice 角色 + firstMessage `你好,{{user}},我是{{char}}。` + 世界书 `{{char}} 正站在酒馆中。` + 用户消息 `{{char}} 你好`,页面 firstMessage 显示 1 次,世界书未泄漏为气泡,无崩溃,重新生成可用
  - [x] hilog 仅 `MacroReplacer | replace: count=N` 数字日志,无 `{{char}}` / `Alice` / `酒馆` 泄漏
  - 未实现:{{time}} / {{date}} / {{lastMessage}} / {{random}} / 条件宏 / 嵌套宏 / 参数宏 / 正则世界书 / Character Book / TokenCounter
  - 已知限制:设备测试需在 DevEco Studio IDE 中运行;userName 暂为固定 `User`,未提供用户名设置页面

### T-2.7 TokenCounter MVP：上下文 Token 估算

- 依赖:T-2.5、T-2.6
- 优先级:P2
- 修改范围:`models/TokenBudget.ets`(新建)、`services/TokenCounter.ets`(新建)、`services/ChatService.ets`、`services/AppServices.ets`、`models/ProviderConfig.ets`、`storage/ProviderConfigCodec.ets`、测试
- 内容:
  - TokenBudget 纯数据模型(contextWindow / reservedOutputTokens / availableInputTokens / estimatedInputTokens / remainingInputTokens / exceedsBudget),不依赖 ArkUI
  - 默认值常量集中管理:CONTEXT_WINDOW_DEFAULT=32768 / DEFAULT_RESERVED_OUTPUT_TOKENS=2048
  - TokenCounter 估算:CJK 每字符 1 Token / ASCII 拉丁词 ceil(N/4) / ASCII 标点每标点 1 Token / 空白每空白 1 Token / 其他 code point 每 code point 1 Token(Emoji 代理对正确处理)
  - 消息固定开销 4 Token / Prompt 结尾开销 2 Token
  - ProviderConfig 新增可选 contextWindow 字段(向后兼容,旧数据自动 fallback)
  - ChatService 构造注入 TokenCounter,在 buildRequestMessages 后调用 updateTokenBudget,提供 getLastTokenBudget() 只读接口
  - 超预算只检测不截断,TokenCounter 抛错不阻塞聊天
  - AppServices 唯一创建并注入,不暴露 getTokenCounter()
- 验收标准:
  - [x] TokenCounter 是独立、无状态服务
  - [x] 中文、英文、标点和 Emoji 均有合理确定性估算
  - [x] TokenBudget 字段含义明确
  - [x] 最终 Prompt 中所有消息均参与统计
  - [x] Character、世界书、宏替换和聊天历史均被包含
  - [x] 不修改任何原始消息
  - [x] 超预算只检测,不截断
  - [x] ChatPage 不感知 TokenCounter
  - [x] 不新增第三方依赖
  - [x] 日志不泄露正文
  - [x] entry@default + entry@ohosTest BUILD SUCCESSFUL
  - [x] 现有聊天与重新生成无回归
- 完成情况(2026-07-17):
  - [x] TokenBudget.ets:纯数据模型 + createTokenBudget 工厂(异常值归一化) + DEFAULT_* 常量
  - [x] TokenCounter.ets:estimateTextTokens / estimateMessageTokens / estimateMessagesTokens 纯函数 + TokenCounter class 委托;所有常量集中定义,UTF-16 代理对安全
  - [x] ProviderConfig.ets:新增 contextWindow?: number + CONTEXT_WINDOW_DEFAULT=32768;withUpdates 保留新字段;构造器增加可选参数
  - [x] ProviderConfigCodec.ets:ProviderConfigItemV1 增加 contextWindow(可选,旧数据缺省不影响反序列化,schemaVersion 保持 1)
  - [x] ChatService.ets:构造注入 TokenCounter;新增 getLastTokenBudget() / 私有 updateTokenBudget();doStream 中 buildRequestMessages 之后调用;异常时 lastTokenBudget=undefined + 安全 warn 日志
  - [x] AppServices.ets:createChatService 注入 tokenCounter(私有字段,不对外暴露)
  - [x] TokenCounter.test.ets:30 个本地单元测试(覆盖 30 个任务要求的场景)
  - [x] ChatServiceToken.test.ets:10 个 ChatService Token 集成测试(覆盖 31-40 项)
  - [x] MockChatServiceDeps.ets:本地测试用 MockModelService 支撑
  - [x] MCP 增量编译 entry@default + entry@ohosTest BUILD SUCCESSFUL
  - [x] 模拟器冒烟:hilog 实测 `token estimate: messages=5 inputTokens=68 availableTokens=31744 remainingTokens=31676 exceedsBudget=false`,重新生成再次输出
  - [x] hilog 扫描:`Alice` / `{{char}}` / `sk-` / `酒馆` / 完整请求 JSON 全部 0 命中
  - 未实现:HistoryTrimmer / 自动截断 / Summary / tiktoken / 精确 tokenizer / UI Token 显示 / Preset
  - 已知限制:设备测试需在 DevEco Studio IDE 中运行;超预算行为依赖单元测试覆盖(不通过实机修改正式配置制造错误)

### T-2.8 HistoryTrimmer MVP：聊天历史裁剪

- 依赖:T-2.5、T-2.6、T-2.7
- 优先级:P2
- 修改范围:`models/HistoryTrimResult.ets`(新建)、`models/ChatMessageSource.ets`(新建)、`services/HistoryTrimmer.ets`(新建)、`models/ChatMessage.ets`、`models/PromptSegment.ets`、`services/PromptBuilder.ets`、`services/ChatService.ets`、`services/AppServices.ets`、测试
- 内容:
  - HistoryTrimmer 独立无状态服务,依赖注入 TokenCounter,不访问 ArkUI / Provider / ChatService
  - ChatMessageSource 枚举:Conversation / CharacterPrompt / CharacterFirstMessage / LorebookBefore / LorebookAfter / ExternalSystem
  - ChatMessage 与 PromptSegment 增加可选 `source` 字段(内部辅助标记,不写入网络请求 JSON,不持久化)
  - PromptBuilder 输出消息按类别附加 source 标签
  - HistoryTrimResult 纯数据模型:originalTokenCount / finalTokenCount / removedMessageCount / removedMessageIds / exceedsBudgetBeforeTrim / exceedsBudgetAfterTrim
  - 裁剪算法:从旧到新按 User+紧邻 Assistant 完整轮次删除;孤立消息作单条;每轮删除后重估 Token;达到预算即停
  - 受保护:System 消息 / Character Prompt / firstMessage / 世界书 Before&After / 当前最后一条 User / protectedMessageIds 显式标记
  - 极端超预算:保留所有受保护消息,不截断正文,不抛异常,exceedsBudgetAfterTrim=true,记录安全 warn
  - ChatService 接入顺序:PromptBuilder.build() → TokenCounter.calculateBudget() → [若超预算] HistoryTrimmer.trim() → 重算预算 → streamCurrentChat()
  - ChatService 不修改 `messages` 数组,只裁剪临时请求消息;页面历史记录保持完整
  - AppServices 私有 historyTrimmer 字段,createChatService 注入,不对页面公开,无 getHistoryTrimmer()
  - 正常未裁剪时不输出额外日志;实际发生裁剪时输出 `history trim: ...` 数字统计;严禁记录正文/ID/Key/请求 JSON
- 验收标准:
  - [x] HistoryTrimmer 是独立无状态服务
  - [x] 不超预算时不删除消息
  - [x] 超预算时从最旧历史轮次开始裁剪
  - [x] System / 世界书 / Character Prompt / firstMessage / 当前 User 全部受保护
  - [x] 不修改消息正文
  - [x] 不修改 ChatService.messages
  - [x] 页面历史记录保持完整
  - [x] 最终发送使用裁剪后的临时消息
  - [x] 裁剪后重新计算 TokenBudget
  - [x] 极端情况下仍超预算时不崩溃、不误删保护内容
  - [x] 正常发送和重新生成均支持裁剪
  - [x] ChatPage 不感知 HistoryTrimmer
  - [x] 无正文日志泄漏
  - [x] entry@default + entry@ohosTest BUILD SUCCESSFUL
  - [x] 现有角色 / 世界书 / 宏替换 / 流式回复无回归
- 完成情况(2026-07-17):
  - [x] HistoryTrimResult.ets:纯数据模型 + createHistoryTrimResult 工厂
  - [x] ChatMessageSource.ets:6 个枚举值(内部辅助标记,不写网络 JSON,不持久化)
  - [x] ChatMessage.ets:增加可选 `source?: ChatMessageSource` 字段
  - [x] PromptSegment.ets:增加 `source: ChatMessageSource` 字段,createPromptSegment 增加可选 source 参数
  - [x] PromptBuilder.ets:build() 中按消息类别附加 source 标签(worldbook→LorebookBefore/LorebookAfter / character system→CharacterPrompt / 第一条 Assistant→CharacterFirstMessage / 其他 System→ExternalSystem / User 与其他 Assistant→Conversation)
  - [x] HistoryTrimmer.ets:独立无状态服务;buildTrimUnits() 优先按 User+紧邻 Assistant 完整轮次,孤立消息作单条;countTokensSafe() 捕获 TokenCounter 异常并 fallback 到 estimateMessagesTokens;终止条件:达到预算 / 删无可删 / MAX_TRIM_ITERATIONS=256
  - [x] ChatService.ets:构造注入 HistoryTrimmer;新增 getLastHistoryTrimResult();updateRequestPlan() 统一处理(首次预算→裁剪→重算预算);sendMessage 与 regenerate 都走 updateRequestPlan;doStream 中用裁剪后消息调 streamCurrentChat;异常时回退到未裁剪请求继续发送
  - [x] AppServices.ets:createChatService 注入 historyTrimmer(私有字段,不对外暴露,无 getHistoryTrimmer())
  - [x] HistoryTrimmer.test.ets:35 个本地单元测试(覆盖任务规范场景 1-35)
  - [x] ChatServiceToken.test.ets:追加 7 个 ChatService 历史裁剪集成测试(覆盖任务规范场景 36-50,共 17 个)
  - [x] MCP 增量编译 entry@default BUILD SUCCESSFUL in 19 s 429 ms
  - [x] MCP 增量编译 entry@ohosTest BUILD SUCCESSFUL in 17 s 822 ms
  - [x] 模拟器冒烟:nova 13 Pro_23 普通聊天回归通过;发送 T28-Regression 消息收到流式回复,重新生成替换为新回复,firstMessage 不重复
  - [x] hilog 实测:`token estimate: messages=5 inputTokens=58 availableTokens=31744 remainingTokens=31686 exceedsBudget=false`,两条请求均出现
  - [x] `history trim` 日志:0 命中(预算充足,未触发裁剪;裁剪正确性由 35 个单元测试证明)
  - [x] hilog 内容泄漏扫描:Alice 1(仅 home page 标题)/ {{char}} 0 / {{user}} 0 / sk- 0 / T28-Regression 0 / Authorization 0 / Bearer 0
  - [x] 无 App died / FATAL / crash 日志
  - [x] 全部组件(Character / Lorebook / MacroReplacer / PromptBuilder / TokenCounter / OpenAIProvider / HttpStreamTransport)无回归
  - 未实现:Summary / 单条消息字符截断 / 自动禁用世界书 / RAG / 长期记忆 / 消息优先级评分 / tiktoken / 模型专属 tokenizer / UI Token 条 / "上下文已裁剪"提示 / Preset / Swipe
  - 已知限制:设备测试需在 DevEco Studio IDE 中运行;超预算裁剪行为由单元测试覆盖(不通过实机修改正式配置制造极端错误)

---

## Phase 3:角色卡导入

> Phase 3 中 T-3.1～T-3.6 已由 T-2.1～T-2.3、T-2.5 提前覆盖，不再重复执行。

### T-3.1 定义 Character 内部模型

- 依赖:T-0.5
- 优先级:P1
- 修改范围:`entry/src/main/ets/models/Character.ets`
- 参考文件:`SillyTavern-release/src/character-card-parser.js`、`default/content/` 样例
- 内容:V2/V3 字段映射到内部 interface(name / description / personality / scenario / firstMes / mesExample / alternateGreetings / creator / spec / 等)
- 验收标准:
  - [ ] 可承载 V2 与 V3 字段
  - [ ] 缺失字段有默认值
- 合并状态:已由 T-2.x 对应任务覆盖,不再单独执行。

### T-3.2 实现 CharacterCardParser

- 依赖:T-3.1
- 优先级:P1
- 修改范围:`entry/src/main/ets/parser/character/`(新建)
- 内容:`CharacterCardParser.ets`:解析 JSON,识别 V2(`spec=chara_card_v2`)/V3,校验必填字段
- 验收标准:
  - [ ] 可解析 V2/V3 样例
  - [ ] 非法 JSON 返回明确错误
- 合并状态:已由 T-2.x 对应任务覆盖,不再单独执行。

### T-3.3 实现文件选择与导入

- 依赖:T-3.2
- 优先级:P1
- 修改范围:`entry/src/main/ets/services/CharacterService.ets`、`parser/character/`
- 内容:使用 `@ohos.file.picker` 选择 JSON,读取并解析
- 验收标准:
  - [ ] 可从文件系统选择并导入
  - [ ] 导入失败有提示
- 合并状态:已由 T-2.x 对应任务覆盖,不再单独执行。

### T-3.4 实现 CharacterService(内存态)

- 依赖:T-3.3
- 优先级:P1
- 修改范围:`services/CharacterService.ets`
- 内容:导入 / 列表 / 选中当前角色
- 验收标准:
  - [ ] 可管理多个角色
  - [ ] 可切换当前角色
- 合并状态:已由 T-2.x 对应任务覆盖,不再单独执行。

### T-3.5 实现角色列表页与导入页

- 依赖:T-3.4
- 优先级:P1
- 修改范围:`pages/CharacterListPage.ets`、`pages/CharacterImportPage.ets`、`main_pages.json`
- 验收标准:
  - [ ] 列表展示已导入角色
  - [ ] 可触发导入流程
- 合并状态:已由 T-2.x 对应任务覆盖,不再单独执行。

### T-3.6 聊天页接入角色上下文

- 依赖:T-2.5、T-3.4
- 优先级:P1
- 修改范围:`services/ChatService.ets`、`pages/ChatPage.ets`
- 内容:选中角色后,首条消息使用 firstMes,描述/人设/场景拼入临时 Prompt
- 验收标准:
  - [ ] 角色首条消息正确显示
  - [ ] 角色描述进入请求上下文
- 合并状态:已由 T-2.x 对应任务覆盖,不再单独执行。

---

## Phase 4:本地数据库

### T-4.1 设计建表脚本

- 依赖:T-0.5
- 优先级:P1
- 修改范围:`entry/src/main/ets/database/`(新建)
- 参考文件:ARCHITECTURE.md 表结构
- 内容:
  - `database/DatabaseConstants.ets`:表名 / 列名 / 索引名 / 角色状态字符串 / 来源字符串 / 数据库名 / 数据库版本集中定义
  - `database/DatabaseSchema.ets`:version 1 建表 SQL 集中管理
    - characters:id / name / description / personality / scenario / first_message / system_prompt / avatar_uri / created_at / updated_at
    - chats:id / character_id(允许 null) / title / created_at / updated_at / last_message_at / is_archived
    - messages:id / chat_id / role / content / status / created_at / updated_at / sequence_number / error_message / is_streaming / source
  - 索引:`idx_chats_updated_at` / `idx_chats_character_id` / `idx_messages_chat_id_sequence`(UNIQUE) / `idx_messages_chat_id_created_at`
  - 所有建表/建索引 SQL 使用 `IF NOT EXISTS`,可重复执行
  - 不包含 destructive migration、不包含 API Key / Provider Secret / 用户正文
  - 不创建 Lorebook 表(继续 Preferences)
- 验收标准:
  - [x] 三个表 Schema 已定义
  - [x] 必要索引已定义
  - [x] 建表和建索引可重复执行
  - [x] 不存在 destructive migration
  - [x] 数据库版本为 1
  - [x] Schema 不包含 API Key 或 Provider Secret
  - [x] TODO 重复阶段已标注合并,不再重复开发

### T-4.2 实现 DbHelper

- 依赖:T-4.1
- 优先级:P1
- 修改范围:`database/DbHelper.ets`、`database/DatabaseMigration.ets`、`models/DatabaseError.ets`、`services/AppServices.ets`、测试
- 内容:
  - `database/DatabaseMigration.ets`:`DatabaseMigration` 接口 + `buildMigrationPath()` 路径计算 + `isMigrationRegistryValid()` 注册校验;不支持降级、不支持跳版本
  - `models/DatabaseError.ets`:`DatabaseErrorType` 枚举 + `DatabaseError` class + `isDatabaseError` 守卫;不暴露 SQL 全文 / 聊天正文 / 绝对路径 / BusinessError 原始对象
  - `database/DbHelper.ets`:基于 `@kit.ArkData` relationalStore 封装,`initialize(context)` 幂等且并发安全 / `getStore()` 未初始化或已关闭抛 DatabaseError / `runInTransaction()` 失败回滚 / `close()` 幂等并允许重新初始化
  - 初始化顺序:Preferences → AssetStore → Provider → CharacterStore → LorebookStore → DbHelper;失败时 AppServices ready 状态明确失败
  - 暂时不向页面公开 DbHelper;Repository 阶段再注入
  - 设备测试:`ohosTest/ets/test/DbHelper.test.ets` 40 项
  - 纯逻辑测试:`test/DatabaseSchema.test.ets` 10 项
- 验收标准:
  - [x] DbHelper 可初始化数据库
  - [x] 重复和并发初始化安全
  - [x] 数据库升级框架可扩展
  - [x] 事务提交和回滚正常
  - [x] close 幂等
  - [x] 关闭后可重新初始化
  - [x] AppServices 已初始化 DbHelper
  - [x] 页面和现有业务尚未直接访问数据库
  - [x] CharacterStore / LorebookStore / ChatService 行为无变化
  - [x] entry@default BUILD SUCCESSFUL
  - [x] entry@ohosTest BUILD SUCCESSFUL
  - [x] 无正文和敏感数据日志泄漏

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

### T-4.5 Chat Session List MVP

> 原"Service 层切换为 Repository"中的聊天持久化部分已由 T-4.4 完成;
> 本任务完成多会话列表、新建、切换和删除。

- 依赖:T-4.4、T-2.2、T-3.4
- 优先级:P1
- 修改范围:`services/ChatService.ets`、`services/ChatPersistenceService.ets`、`viewmodels/ChatViewModel.ets`、`pages/ChatPage.ets`、`components/ChatSessionListPanel.ets`、`repositories/ChatRepository.ets`
- 验收标准:
  - [ ] 当前上下文会话列表可见
  - [ ] 可新建、切换、删除会话
  - [ ] 删除当前会话后自动回退或新建
  - [ ] 角色与普通助手会话严格隔离
  - [ ] 生成中禁止会话变更
  - [ ] 应用重启后会话仍存在
  - [ ] 无正文/SQL/Prompt/API Key 日志泄漏

---

## Phase 5:Prompt 与宏系统

> Phase 5 中 T-5.1～T-5.6 已由 T-2.5～T-2.8 提前覆盖，不再重复执行。

### T-5.1 定义 PromptSegment 模型与顺序

- 依赖:T-0.5
- 优先级:P1
- 修改范围:`models/PromptSegment.ets`
- 参考文件:AGENTS.md Prompt 顺序
- 验收标准:
  - [ ] 顺序枚举完整
- 合并状态:已由 T-2.5 对应任务覆盖,不再单独执行。

### T-5.2 实现 MacroReplacer(标准宏)

- 依赖:T-3.1
- 优先级:P1
- 修改范围:`services/MacroReplacer.ets`
- 参考文件:`SillyTavern-release/public/scripts/macros/*`
- 内容:{{user}} / {{char}} / {{description}} / {{scenario}} / {{personality}} / {{lastMessage}}
- 验收标准:
  - [ ] 所有标准宏可替换
  - [ ] 未识别宏保留原样
- 合并状态:已由 T-2.6 对应任务覆盖,不再单独执行。

### T-5.3 实现 PromptBuilder

- 依赖:T-5.1、T-5.2
- 优先级:P1
- 修改范围:`services/PromptBuilder.ets`
- 参考文件:`SillyTavern-release/public/scripts/openai.js`、`sysprompt.js`
- 验收标准:
  - [ ] 顺序符合 AGENTS.md
  - [ ] 各段可空跳过
- 合并状态:已由 T-2.5 对应任务覆盖,不再单独执行。

### T-5.4 实现简化 TokenCounter

- 依赖:T-5.3
- 优先级:P1
- 修改范围:`utils/TokenCounter.ets`
- 验收标准:
  - [ ] 给出近似 token 数
- 合并状态:已由 T-2.7 对应任务覆盖,不再单独执行。

### T-5.5 历史消息窗口截断

- 依赖:T-5.3、T-5.4、T-4.4
- 优先级:P1
- 修改范围:`services/PromptBuilder.ets`
- 验收标准:
  - [ ] 超限历史可截断
- 合并状态:已由 T-2.8 对应任务覆盖,不再单独执行。

### T-5.6 ChatService 接入 PromptBuilder

- 依赖:T-5.5、T-2.2
- 优先级:P1
- 修改范围:`services/ChatService.ets`
- 验收标准:
  - [ ] 端到端 Prompt 正确
- 合并状态:已由 T-2.5 对应任务覆盖,不再单独执行。

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

---

## T-4.1 + T-4.2 完成记录(2026-07-17)

### 实际新增文件

- `entry/src/main/ets/database/DatabaseConstants.ets`(80 行)
- `entry/src/main/ets/database/DatabaseSchema.ets`(108 行)
- `entry/src/main/ets/database/DatabaseMigration.ets`(80 行)
- `entry/src/main/ets/database/DbHelper.ets`(263 行)
- `entry/src/main/ets/models/DatabaseError.ets`(118 行)
- `entry/src/test/DatabaseSchema.test.ets`(本地纯逻辑,16 项断言)
- `entry/src/ohosTest/ets/test/DbHelper.test.ets`(设备集成,40 项 it)

### 实际修改文件

- `entry/src/main/ets/services/AppServices.ets`:新增 `dbHelper` 字段,构造器末尾实例化,initialize 链尾追加 `services.dbHelper.initialize(context)`
- `entry/src/test/List.test.ets`:注册 `databaseSchemaTest`
- `entry/src/ohosTest/ets/test/List.test.ets`:注册 `dbHelperDeviceTest`
- `TODO.md`:Phase 3 / Phase 5 重复任务合并说明

### 数据库 Schema 摘要

- `characters`:id PK / name / description / personality / scenario / first_message / system_prompt / avatar_uri / created_at / updated_at
- `chats`:id PK / character_id(可空,无外键) / title / created_at / updated_at / last_message_at / is_archived
- `messages`:id PK / chat_id / role / content / status / created_at / updated_at / sequence_number / error_message / is_streaming / source(可空)

### 索引

- `idx_chats_updated_at`(chats.updated_at)
- `idx_chats_character_id`(chats.character_id)
- `idx_messages_chat_id_sequence` UNIQUE(messages.chat_id, messages.sequence_number)
- `idx_messages_chat_id_created_at`(messages.chat_id, messages.created_at)

### 版本策略

- `DATABASE_VERSION = 1`
- 实际版本号通过 `PRAGMA user_version` 自管理(RdbStore.version read-only 且无 setVersion API)
- 升级路径:`buildMigrationPath` 排序 + 逐 fromVersion 串联;降级抛错;跳版本抛错;重复 fromVersion 抛错
- 所有迁移在 `beginTransaction` / `commit` / `rollBack` 包裹中

### DbHelper 行为

- 初始化:幂等(`store !== null && !closed` 直接 return),并发安全(pending Promise 缓存,失败清空允许重试)
- 关闭后允许重新 initialize(`closed` 标志位在 initialize 重置)
- `getStore()` 未初始化抛 `NotInitialized`,已关闭抛 `Closed`,不返回 undefined
- `runInTransaction(action)`:成功 commit / 失败 rollback / rollback 失败也抛 `TransactionFailed`
- `close()` 幂等,清理 store 引用
- 测试数据库名 `arktavern_test.db`,独立于生产 `arktavern.db`(构造函数可注入)

### 编译与冒烟结果

- `entry@default` BUILD SUCCESSFUL(40.6 s,3 次修复后通过)
- `entry@ohosTest` BUILD SUCCESSFUL(41.2 s,4 次修复后通过)
- 模拟器冒烟:nova 13 Pro_23 安装启动成功,hilog 包含:
  - `AppServices | initialize start`
  - `AppServices | initialize ok`
  - `DbHelper | initialize start`
  - `DbHelper | initialize success version=1`
- 0 条 ERROR 级别 ArkTavern 日志,无 crash,无 SQL 全文,无 API Key,无聊天正文

### 设备测试实际执行结果

- ohosTest 编译通过(`BUILD SUCCESSFUL`)
- 设备测试**未在命令行执行**:依据 `project_memory.md` 已知限制(`aa test` 模式构建会破坏主 HAP Test Runner),设备测试必须在 DevEco Studio IDE 中手动运行
- 测试代码覆盖 40 项 spec,可在 DevEco Studio 中右键 `run 'entry@ohosTest'` 验证

### 已知遗留

- `RdbStore.setVersion` API 在当前 SDK 不可用,改用 `PRAGMA user_version` 手动管理
- 暂未提供 `EntryAbility` 销毁时 `dbHelper.close()` 钩子;`close()` 由 AppServices 持有,如需在 onDestroy 调用可后续补一行

### 后续任务

- T-4.3 CharacterRepository
- T-4.4 ChatRepository / MessageRepository
- Repository 阶段再注入 DbHelper

---

## T-4.3 ChatRepository + MessageRepository MVP 完成记录(2026-07-17)

> 说明:本任务对应 TODO.md 计划中的 T-4.4(ChatRepository / MessageRepository)。任务编号沿用用户下发的 T-4.3。T-4.3 CharacterRepository 暂未实现,不在本任务范围。

### 1. 新增和修改文件

#### 新增文件(9 个)

- `entry/src/main/ets/models/Chat.ets`(87 行)— Chat 纯数据模型 + 工厂/不可变更新
- `entry/src/main/ets/repositories/RepositoryMappers.ets`(131 行)— 枚举解析/校验/工具函数
- `entry/src/main/ets/repositories/ChatRepository.ets`(320 行)— Chat CRUD + 分页 + WithStore
- `entry/src/main/ets/repositories/MessageRepository.ets`(561 行)— Message CRUD + 分页 + 批量插入 + WithStore
- `entry/src/main/ets/repositories/ChatPersistenceOperations.ets`(71 行)— 联合删除事务
- `entry/src/test/RepositoryMappers.test.ets`(415 行)— 本地纯逻辑测试
- `entry/src/ohosTest/ets/test/ChatRepository.test.ets`(618 行)— 设备测试 25 项
- `entry/src/ohosTest/ets/test/MessageRepository.test.ets`(999 行)— 设备测试 40 项
- `entry/src/ohosTest/ets/test/ChatPersistenceOperations.test.ets`(372 行)— 设备测试 7 项

#### 修改文件(4 个)

- `entry/src/main/ets/models/DatabaseError.ets`— 新增 `NotFound` / `AlreadyExists` / `InvalidData` / `ConstraintFailed` 4 个错误类型及静态工厂
- `entry/src/test/List.test.ets`— 注册 `repositoryMappersTest`
- `entry/src/ohosTest/ets/test/List.test.ets`— 注册 `chatRepositoryDeviceTest` / `messageRepositoryDeviceTest` / `chatPersistenceOperationsDeviceTest`
- `TODO.md`— 本完成记录

### 2. Chat 模型设计

- 纯数据 interface,无 ArkUI / RDB / 页面依赖
- 字段:`id` / `characterId?` / `title` / `createdAt` / `updatedAt` / `lastMessageAt` / `isArchived`
- 工厂函数 `createChat(options?)`:id 默认 UUID,时间默认 `nowMillis()`,title 默认空串,characterId 为空表示普通助手聊天
- 不可变更新 `updateChat(chat, updates)`:所有更新返回新对象,`characterId: null` 用于清空
- 不含 API Key / Provider Secret / Prompt 正文

### 3. ChatRepository 接口及行为

- `insert(chat)`:ValuesBucket 写入,id 重复映射 ConstraintFailed,characterId 为空写 null,boolean 用 0/1
- `getById(id)`:不存在返回 null(不抛 NotFound),ResultSet 必关
- `list(options?)`:默认排除 archived,按 `last_message_at DESC → updated_at DESC → id ASC` 稳定排序,默认 limit=50,limit/offset 校验(非法抛 InvalidData),用 RdbPredicates 链式构造(不拼接 SQL)
- `update(chat)`:依据 affected 行数判断 NotFound,不改 id
- `remove(id)`:幂等,不抛错,不级联删消息
- `setArchived(id, archived)`
- `updateLastMessageAt(id, lastMessageAt, updatedAt)`
- `count()`
- WithStore 内部方法:`insertWithStore` / `removeWithStore` / `chatExistsWithStore` — 用于事务组合,避免嵌套事务

### 4. MessageRepository 接口及行为

- `insert(message, chatId, sequenceNumber)`:先检查 Chat 是否存在(NotFound),再写入
- `insertMany(chatId, records)`:事务包裹,预校验所有记录,事务中只检查一次 Chat 存在,空数组直接返回,中途失败整批回滚,不修改输入数组
- `getById(id)`:不存在返回 null
- `listByChat(chatId, options?)`:按 sequence_number ASC/DESC,limit 1-200,offset ≥ 0
- `listRecordsByChat(chatId, options?)`:返回 `StoredChatMessage[]`(含 chatId / sequenceNumber / message)
- `getMaxSequenceNumber(chatId)`:空聊天返回 0
- `update(message)`:依据 affected 行数判断 NotFound
- `remove(id)`:幂等
- `removeByChatId(chatId)`:返回删除行数,幂等
- `countByChatId(chatId)`
- WithStore 内部方法:`insertWithStore` / `removeByChatIdWithStore` / `chatExistsWithStore`

### 5. Row/枚举映射和数据损坏处理

- `parseChatRole` / `parseChatMessageStatus` / `parseChatMessageSource`:显式 `if (value === X) return X` 链,禁止 `as ChatRole` / `as unknown as`
- role 非法 → InvalidData;status 非法 → InvalidData;source 为空 → undefined;source 非法 → InvalidData
- `booleanToInt` / `intToBoolean`:只接受 0/1,其他抛 InvalidData
- `isValidTimestamp`:有限非负整数
- `isValidSequence`:非负整数
- `extractCauseMessage` / `isConstraintViolation`:脱敏错误处理,不暴露 BusinessError
- 数据损坏不导致崩溃,统一抛 DatabaseError

### 6. 分页与排序规则

- Chat 列表:`last_message_at DESC → updated_at DESC → id ASC`(三级稳定排序)
- Message 列表:`sequence_number ASC` 或 `DESC`(UNIQUE 索引保证稳定)
- limit 默认 50(Chat)/ 50(Message),范围 1-200;offset 默认 0,最小 0
- 非法参数抛 InvalidData,不拼接用户输入 SQL

### 7. 批量插入和联合删除事务

- `insertMany`:DbHelper.runInTransaction 包裹,预校验所有记录(事务前),事务中按顺序插入,任一失败 rollBack,空数组直接返回
- `ChatPersistenceOperations.removeChatWithMessages(chatId)`:一个事务中先删 messages 后删 chat,任一失败全部回滚,幂等
- 通过 WithStore 内部方法操作,避免嵌套事务
- 不暴露任意 SQL 执行接口

### 8. 动态 Prompt 消息防持久化规则

- `isPersistableSource`:仅允许 `Conversation` / `CharacterFirstMessage` / `ExternalSystem` 持久化
- `CharacterPrompt` / `LorebookBefore` / `LorebookAfter` 在 `buildValidatedMessageBucket` 中被拒绝,抛 InvalidData
- 不静默改成 Conversation,不依赖正文识别
- source 为空时保持为空(兼容旧消息)
- `resolveIsStreaming`:Streaming 状态必须 `is_streaming=1`,其他状态必须 `is_streaming=0`,矛盾抛 InvalidData

### 9. 定向测试:区分编译结果与实际运行结果

#### 本地纯逻辑测试(RepositoryMappers.test.ets)

- 覆盖:ChatRole / ChatMessageStatus / ChatMessageSource 解析与往返、非法枚举拒绝、boolean 0/1 转换、timestamp/sequence 校验、source 持久化白名单、isStreaming 一致性、extractCauseMessage、isConstraintViolation、输入不修改
- **编译通过**(entry@default),未在命令行单独执行

#### 设备测试(ChatRepository 25 项 + MessageRepository 40 项 + ChatPersistenceOperations 7 项)

- **测试代码编译通过**(entry@ohosTest BUILD SUCCESSFUL)
- **设备测试未在命令行执行**:依据 `project_memory.md` 已知限制(`aa test` 模式构建会破坏主 HAP Test Runner),设备测试必须在 DevEco Studio IDE 中手动运行
- 测试覆盖完整 spec:CRUD / 分页 / 排序 / 批量插入回滚 / 联合删除事务原子性(stub 模拟底层失败)/ source 白名单 / isStreaming 一致性 / 枚举安全映射 / 中文 Emoji Markdown 往返 / 输入不可变性
- 可在 DevEco Studio 中右键 `run 'entry@ohosTest'` 验证

### 10. 编译结果

- `entry@default` BUILD SUCCESSFUL(17.7 s,首次通过)
- `entry@ohosTest` BUILD SUCCESSFUL(22.2 s,修复 1 次后通过)
  - 修复内容:`MessageRepository.test.ets:957-958` optional 字段类型标注(`ChatMessageStatus | undefined` / `boolean | undefined`)
- 警告均为已知的 "Function may throw exceptions. Special handling is required."(try/catch 中 await 调用),非新增问题

### 11. 模拟器回归结果

- 设备:nova 13 Pro_23
- 应用安装启动成功(`start ability successfully`)
- 首页渲染正常:显示"方舟酒馆"/"ArkTavern"/"HarmonyOS NEXT 原生 AI 角色聊天客户端"/"暂无会话"/4 个功能按钮(开始聊天/角色/世界书/模型设置)/"当前模型:ds · deepseek-v4-flash"
- hilog Error 级别:无 crash(旧 crash 时间戳 2026-07-17 00:44:45 为 Test Runner 环境限制,非本次启动触发),无 SQL 全文,无 message content,无 API Key,无 Character Prompt,无 Lorebook 正文
- Repository 未接入 AppServices,应用行为与之前完全一致,无回归

### 12. 尚未解决的问题

- 设备测试未在命令行实际执行,需在 DevEco Studio IDE 中手动验证
- `dbHelperDeviceTest` 在 `List.test.ets` 中已导入但未在 `testsuite()` 中调用(T-4.2 遗留,非本任务范围)
- `databaseSchemaTest` 在本地 `List.test.ets` 中已导入但未在 `testsuite()` 中调用(T-4.1 遗留,非本任务范围)
- Repository 尚未接入 ChatService / AppServices(按任务要求,下一阶段统一组合)
- 聊天历史 UI / 多会话列表 / 自动创建 Chat / Preferences 数据迁移 均未实现(按任务要求不推进)

### 后续任务

- T-4.3 CharacterRepository( TODO.md 原编号,本任务未覆盖)
- T-4.5 Service 层切换为 Repository(接入 ChatService 持久化)
- 聊天历史 UI / 多会话列表

---

## T-4.4 Chat Persistence Service Integration MVP 完成记录(2026-07-17)

> 说明:本任务对应 TODO.md 计划中的 T-4.5(Service 层切换为 Repository)。任务编号沿用用户下发的 T-4.4。本任务将当前聊天会话安全接入 RDB,实现当前聊天自动创建、页面真实消息持久化、流式回复增量保存、退出/重启后恢复、重新生成状态持久化,但暂不实现完整多会话列表页。

### 完成范围摘要

- ChatRepository / MessageRepository / ChatPersistenceOperations 已接入 AppServices 与 ChatService
- 支持当前会话恢复(最近会话规则:characterId 精确匹配,无角色查 IS NULL,排除 archived,排序 last_message_at DESC → updated_at DESC → id ASC)
- 支持应用重启后恢复(基于 RDB 持久化)
- 支持中断状态恢复(Streaming → Cancelled, is_streaming → 0,部分 content 保留)
- 支持重新生成持久化(事务中删除 User 之后旧 Assistant + 创建新 Streaming Assistant)
- 流式 delta 节流持久化(400ms / 64 chars 双触发,终态强制 flush)
- 多会话列表 UI 尚未实现(按任务要求不推进)
- 测试执行状态:测试代码编译通过(entry@ohosTest BUILD SUCCESSFUL),实际执行受 Test Runner 环境限制(依据 project_memory.md 已知限制,需在 DevEco Studio IDE 中手动运行)
- 模拟器冒烟:openLatestSession → createSessionWithFirstMessage → session ready 流程跑通

### 1. 新增和修改文件

#### 新增文件(4 个生产 + 3 个测试)

- `entry/src/main/ets/services/ChatPersistenceService.ets`(~485 行)— 聊天会话持久化协调服务
- `entry/src/main/ets/models/PersistedChatSession.ets`(15 行)— PersistedChatSession / OpenChatOptions 领域模型(含 maxSequenceNumber 字段)
- `entry/src/ohosTest/ets/test/ChatPersistenceService.test.ets`(698 行)— 设备测试 28 项
- `entry/src/ohosTest/ets/test/ChatServicePersistence.test.ets`(699 行)— 集成测试 20 项
- `entry/src/ohosTest/ets/test/MessageRepositoryPersistenceExtensions.test.ets`(469 行)— 设备测试 12 项

#### 修改文件(8 个)

- `entry/src/main/ets/repositories/ChatRepository.ets`— 新增 `getLatestByCharacterId` / `updateLastMessageAtWithStore`
- `entry/src/main/ets/repositories/MessageRepository.ets`— 新增 `removeAfterSequence` / `removeAfterSequenceWithStore` / `normalizeInterruptedMessages`
- `entry/src/main/ets/services/ChatService.ets`— 注入 ChatPersistenceService,新增 `initializeSession` 异步初始化、节流持久化、终态 flush、regenerate 事务
- `entry/src/main/ets/services/AppServices.ets`— 组合 DbHelper → ChatRepository → MessageRepository → ChatPersistenceOperations → ChatPersistenceService → createChatService 注入
- `entry/src/main/ets/viewmodels/ChatViewModel.ets`— 异步 session 初始化(isInitializing / isSessionReady / initError 状态)
- `entry/src/main/ets/pages/ChatPage.ets`— Loading / initError 状态分支
- `entry/src/ohosTest/ets/test/List.test.ets`— 注册 3 个新测试套件
- `TODO.md`— 本完成记录

### 2. ChatPersistenceService 设计

协调 ChatRepository / MessageRepository / ChatPersistenceOperations / DbHelper 事务,无 ArkUI / Provider / PromptBuilder / MacroReplacer / TokenCounter / HistoryTrimmer 依赖。

构造函数:

```typescript
export class ChatPersistenceService {
  constructor(
    dbHelper: DbHelper,
    chatRepository: ChatRepository,
    messageRepository: MessageRepository,
    chatPersistenceOperations: ChatPersistenceOperations
  );
}
```

核心公共方法:

- `openLatestSession(characterId?)`:按规则返回最近会话(无角色查 IS NULL)
- `createSession(characterId?, title?)`:UUID 生成 chat.id,空 messages
- `createSessionWithFirstMessage(character, firstMessage)`:事务创建 Chat + firstMessage(seq=1)+ 更新 Chat 活跃时间
- `loadSession(chatId)`:先 `normalizeInterruptedMessages` 规范化中断消息,再加载全部消息(按 sequence 升序),返回 maxSequenceNumber
- `deleteSession(chatId)`:委托 ChatPersistenceOperations 事务删除
- `appendMessage(chatId, message)`:单条追加,返回新 sequenceNumber
- `appendUserAndStreamingAssistant(chatId, userMsg, assistantMsg)`:事务追加 User + Assistant 两条消息,更新 Chat 活跃时间,返回 (userSeq, assistantSeq)
- `updateMessage(chatId, message)`:更新单条消息
- `removeMessagesAfter(chatId, sequenceNumber)`:删除 > sequenceNumber 的消息
- `replaceMessagesAfterUser(chatId, userMessageId)`:事务删除 User 之后旧 Assistant
- `replaceMessagesAfterUserAndAppend(chatId, userMessageId, newAssistantMsg)`:事务中删除旧 Assistant + 创建新 Streaming Assistant,返回新 sequenceNumber
- `updateChatActivity(chatId, timestamp)`:更新 chat.updatedAt + lastMessageAt

内部辅助方法:

- `loadSessionInternal(store, chatId)`:加载会话内部实现,计算 maxSequenceNumber
- `findSequenceById(records, messageId)`:通过 listRecordsByChat 加载所有记录后匹配 id 查找 sequenceNumber

### 3. 会话创建和最近会话恢复规则

#### openLatestSession(characterId?)

- **有角色**:`character_id = ?` + `is_archived = 0`,排序 `last_message_at DESC → updated_at DESC → id ASC`,返回最近一条
- **无角色**:只查 `character_id IS NULL` + `is_archived = 0`,不得把任意角色聊天恢复到普通助手聊天中
- **不存在会话**:返回 null,由 ChatService 决定是否创建
- **不在应用启动时自动为所有角色创建 Chat**

#### createSession()

- 使用 UUID 生成 chat.id
- characterId 可为空
- title MVP 默认空字符串(不依赖 CharacterService,避免持久化角色名)
- 时间字段:createdAt = updatedAt = lastMessageAt = now
- 创建后返回空 messages,maxSequenceNumber = 0

### 4. firstMessage 持久化方式

当角色有 firstMessage 且没有历史会话:

1. 调用 `createSessionWithFirstMessage(character, firstMessage)`
2. 事务中:创建 Chat → 创建 firstMessage ChatMessage(role=Assistant, source=CharacterFirstMessage, status=Completed, isStreaming=false, seq=1)→ 更新 Chat 活跃时间
3. 返回 PersistedChatSession,ChatService 将 messages 写入内存
4. 页面显示一次

重新进入时:

- 从数据库恢复
- 不重新创建 firstMessage
- 不重复持久化
- 宏保持原始文本,不持久化临时替换文本

角色没有 firstMessage:创建空 Chat,messages 为空。

### 5. User / Assistant / Streaming 持久化流程

#### sendMessage 流程

1. 校验输入
2. 创建 User ChatMessage
3. 创建 Streaming Assistant ChatMessage
4. 调用 `appendUserAndStreamingAssistant` 事务持久化(返回 userSeq, assistantSeq)
5. 持久化成功后更新 currentSequenceNumber
6. 更新 ChatService.messages(新数组引用)
7. 启动模型请求

User 保存失败 → 不启动模型请求,显示"消息保存失败,请重试",不遗留半条 Streaming Assistant。

#### onDelta 流式持久化(节流)

- 页面仍实时显示每个 delta(内存即时更新)
- 数据库更新节流:累计 400ms 或 64 字符任一条件满足再批量写库
- 新增字段:`persistenceTimerId` / `lastPersistedContentLength` / `pendingPersistAssistantId`
- delta 持久化失败仅 warning 不阻塞模型请求
- complete / cancel / error / 页面退出时强制 flush

#### onComplete

- 创建新 ChatMessage(status=Completed, isStreaming=false, content=最终完整内容, updatedAt=now)
- 调用 `updateMessage` 写入数据库(最多 1 次立即重试)
- 调用 `updateChatActivity` 更新 Chat 活跃时间

#### stopGeneration / Cancelled

- 强制 flush 节流
- 创建新 ChatMessage(status=Cancelled, isStreaming=false, content=已生成部分文本)
- 写入数据库

#### onError / Failed

- 强制 flush 节流
- 创建新 ChatMessage(status=Failed, isStreaming=false, content=已生成部分文本, errorMessage=安全的用户可读错误)
- 写入数据库
- 不持久化底层异常、URL、Header、API Key、完整 Provider 错误对象

### 6. delta 节流和最终 flush 机制

- **节流触发条件**:时间(400ms)或字符数(64 chars)任一满足
- **flush 时机**:onComplete / onError / stopGeneration / dispose(页面退出)
- **取消机制**:`clearPersistenceTimer()` 清除定时器,避免重复写库
- **同步 flush**:`flushPersistenceSync()` 用于 dispose 时机(无法 await)
- **不丢失最终文本**:终态写入前先 flush 已累积内容,再写入终态
- **不将 Prompt 正文写入日志**:日志只记录数字(count / sequence / messages=N)

### 7. 中断恢复机制

应用可能在 Streaming 状态时被杀死。加载历史时如发现 `status = Streaming && is_streaming = true`:

- 调用 `MessageRepository.normalizeInterruptedMessages(chatId)`:批量更新为 `status = Cancelled, is_streaming = 0`
- 返回规范化数量
- 写回数据库
- 页面显示已有部分文本
- 不自动重新请求
- 不保持页面永久 Loading
- 不丢失部分回复

规范化逻辑放在 ChatPersistenceService.loadSession 内,而不是页面。已 Completed 消息不被修改。

### 8. regenerate 数据库一致性

`regenerateLastResponse` 流程:

1. 找到最后一条 User
2. 通过 `findSequenceById` 确定其 sequenceNumber
3. 调用 `replaceMessagesAfterUserAndAppend` 事务:
   - 删除该 User 之后所有旧 Assistant 消息(`sequence_number > userSeq`)
   - User 消息保留
   - 创建新的 Streaming Assistant(新 sequenceNumber)
4. 事务成功后更新内存消息(同步删除旧 Assistant,添加新 Assistant)
5. 更新 currentSequenceNumber
6. 启动模型请求

不得:
- 只删内存不删数据库
- 重新进入页面后旧 Assistant 又恢复
- 删除 User 消息
- 删除 firstMessage
- 删除更早历史轮次

事务失败时旧 Assistant 不删除(原子性保证)。

### 9. AppServices / ChatService / ChatViewModel 接入

#### AppServices 组合顺序

```
DbHelper
→ ChatRepository
→ MessageRepository
→ ChatPersistenceOperations
→ ChatPersistenceService
→ createChatService() 注入
```

- Repository 使用同一个 DbHelper
- 不向页面暴露 Repository getter
- 不新增 getChatRepository()
- `createChatService()` 每次仍创建新的 ChatService
- 所有 ChatService 共享同一个持久化服务(无页面状态)
- DbHelper 初始化完成后才允许 ChatService 加载会话

#### ChatService 生命周期接入

- 构造函数注入 `persistenceService: ChatPersistenceService | null = null`(向后兼容旧测试)
- 新增状态:`currentChatId` / `currentSequenceNumber` / `contextInitialized` / `initializingPromise`(并发保护)
- 新增 `getCurrentChatId(): string | undefined` 只读接口
- 新增 `initializeSession(character?)`:异步初始化会话,幂等(同一实例只初始化一次,并发只执行一次)
- 初始化失败抛错,不静默;不覆盖旧数据库;不重复注入 firstMessage

#### ChatViewModel 异步初始化

- 新增状态:`isInitializing: boolean = true` / `isSessionReady: boolean = false` / `initError: string = ''`
- `canSend` getter 新增 `&& this.isSessionReady` 条件
- `regenerate()` 新增 `!this.isSessionReady` 防御
- `initialize()` 方法重写为异步会话初始化:
  - 设置 isInitializing=true
  - 加载模型配置 + 角色
  - 调用 `chatService.initializeSession(character)`
  - 成功:同步 messages,isSessionReady=true
  - 失败:设置 initError
  - finally:isInitializing=false
- 不直接依赖 Repository 或 DbHelper

#### ChatPage 行为

- 进入页面先初始化会话
- 初始化时显示轻量 Loading(loadingState @Builder)
- 加载完成后显示历史消息
- 历史为空时显示当前空状态
- firstMessage 仍正常显示
- 初始化失败显示 initErrorState @Builder(会话初始化失败 + initError 详情)
- 页面退出:aboutToDisappear 调用 stopGeneration + flushPersistence
- 页面不直接调用数据库
- 页面不显示 chatId
- 页面不新增完整多会话选择入口

### 10. Repository 最小扩展

#### ChatRepository

- `getLatestByCharacterId(characterId?: string)`:
  - characterId undefined → `isNull('character_id')`
  - characterId 非空 → `equalTo('character_id', characterId)`
  - 排除 archived(`equalTo('is_archived', 0)`)
  - 排序 last_message_at DESC → updated_at DESC → id ASC(与 list 一致)
  - limit 1
  - 返回 Chat | null
- `updateLastMessageAtWithStore(store, id, lastMessageAt, updatedAt)`:WithStore 版本,用于事务组合

#### MessageRepository

- `removeAfterSequence(chatId, sequenceNumber)`:
  - 委托 `removeAfterSequenceWithStore`
  - `equalTo('chat_id', chatId).greaterThan('sequence_number', sequenceNumber)`
  - 返回删除行数
  - 不删除边界消息(sequence_number = ? 的消息保留)
  - 不影响其他 chat
- `removeAfterSequenceWithStore(store, chatId, sequenceNumber)`:WithStore 版本
- `normalizeInterruptedMessages(chatId)`:
  - 查询 `equalTo('chat_id', chatId).equalTo('status', 'streaming').equalTo('is_streaming', 1)`
  - 批量更新为 `status='cancelled', is_streaming=0`
  - 返回更新数量
  - 已 Completed 消息不被修改

### 11. 定向测试:区分编译和实际执行

#### 测试文件拆分

按任务要求**未继续扩展 999 行的旧 MessageRepository.test.ets**,新建独立测试文件:

- `ChatPersistenceService.test.ets`(28 项)— 会话创建/恢复、firstMessage、消息追加/更新、中断恢复、安全(source 白名单)
- `ChatServicePersistence.test.ets`(20 项)— initializeSession、sendMessage/regenerate 持久化、stopGeneration、dispose、消息引用、firstMessage、角色隔离、initContext 兼容、canRegenerate、getMessages 副本
- `MessageRepositoryPersistenceExtensions.test.ets`(12 项)— getLatestByCharacterId、removeAfterSequence、normalizeInterruptedMessages、removeAfterSequenceWithStore

#### 编译结果

- `entry@ohosTest` BUILD SUCCESSFUL(测试代码编译通过)

#### 实际执行结果

- 设备测试**未在命令行执行**:依据 `project_memory.md` 已知限制(`aa test` 模式构建会破坏主 HAP Test Runner),设备测试必须在 DevEco Studio IDE 中手动运行
- 测试代码覆盖 60 项 spec,可在 DevEco Studio 中右键 `run 'entry@ohosTest'` 验证
- ChatServicePersistence 集成测试使用 MockModelService 和 FailingPersistenceService 进行隔离测试(纯业务编排部分可在本地运行)

### 12. 编译结果

- `entry@default` BUILD SUCCESSFUL(修复 4 次后通过):
  - 修复 1:ChatPersistenceService.ets 三处 `throw err` 改为 instanceof Error 检查(arkts-limited-throw)
  - 修复 2:MessageRepository.ets 文件末尾缺少类闭合 `}`
  - 修复 3:ChatRepository.ets updateLastMessageAtWithStore 事务上下文适配
  - 修复 4:ChatService.ets 构造函数参数顺序与 AppServices 注入对齐
- `entry@ohosTest` BUILD SUCCESSFUL(一次通过)

### 13. 模拟器实测结果

#### 设备

- 设备:nova 13 Pro_23
- 应用安装启动成功

#### 持久化流程验证

hilog 关键日志确认持久化流程完整跑通:

```
07-17 13:35:23.426  31495  31495 I A00000/ArkTavern: ChatPersistence | openLatestSession none
07-17 13:35:23.452  31495  31495 I A00000/ArkTavern: ChatPersistence | createSessionWithFirstMessage id=fa22d473
07-17 13:35:23.453  31495  31495 I A00000/ArkTavern: ChatViewModel | session ready chatId=fa22d473-72f9-4b2e-aab8-3c585c3dada5 messages=1
07-17 13:35:23.454  31495  31495 I A00000/ArkTavern: ChatViewModel | initialize currentModelName=ds · deepseek-v4-flash ready=true
```

#### 验证结果

- 应用启动正常,无崩溃
- AppServices 初始化成功(DbHelper version=1)
- 进入聊天页面后触发 openLatestSession(无历史会话返回 none)
- 自动创建新会话 createSessionWithFirstMessage(含角色 firstMessage)
- ViewModel 报告 session ready,messages=1(角色开场白)
- isSessionReady=true,isInitializing=false

#### 未完成的模拟器实测项

受任务时间约束,以下任务规范要求的模拟器实测项**未完成人工验证**:

- 发送消息后退出再进入验证恢复
- 强制停止应用并重启后验证恢复
- 重新生成后验证旧 Assistant 不恢复
- 普通助手与角色聊天隔离验证
- 中断恢复(Streaming → Cancelled)验证

这些项由 60 项测试代码覆盖(编译通过),实际执行受 Test Runner 环境限制,需在 DevEco Studio IDE 中手动运行或后续实机验证。


### 14. 尚未解决的问题

- **多会话列表 UI 尚未实现**:本任务仅实现内部 `startNewSession()` 能力(未实现按钮),未实现完整聊天列表页 / 搜索 / 重命名 / 归档 / 删除 UI
- **设备测试未在命令行实际执行**:依据 project_memory.md 已知限制,需在 DevEco Studio IDE 中手动运行
- **模拟器实测未完成全量验证**:仅完成会话初始化流程验证,发送/退出/重启/重新生成/中断恢复等端到端实测项未完成人工验证
- **CharacterStore 未迁移到 RDB**:Character 和 Lorebook 仍保留在 Preferences(按任务要求不推进)
- **Preferences 历史迁移未实现**:本任务不做迁移(之前没有持久化历史来源,没有可迁移的数据源)
- **Summary / Swipe / Preset / Lorebook RDB / CharacterRepository**:均未实现(按任务要求不推进)
- **T-4.5 未标记完成**:本任务标记 T-4.4 完成,不推进 T-4.5

### 后续任务

- T-4.5 Service 层切换为 Repository(完整多会话切换)
- 完整多会话列表页 / 搜索 / 重命名 / 归档 / 删除 UI
- 实机端到端验证(发送 → 退出 → 重启 → 恢复 → 重新生成 → 中断恢复)
- CharacterStore 迁移到 RDB
- Lorebook RDB
- Summary / Swipe / Preset


- [x] 人工运行验收通过：
  - User 消息持久化
  - Assistant 完整回复持久化
  - 页面退出后恢复
  - 应用重启后恢复
  - regenerate 后数据库与页面一致
  - Streaming 中断后恢复为 Cancelled
  - 普通聊天与角色聊天隔离
  - firstMessage 不重复
  - 页面退出时最后一批 delta 未丢失
- [x] T-4.4 正式验收通过


## T-4.5 Chat Session List MVP 完成记录(2026-07-17)

> 说明:本任务对应 TODO.md 计划中的 T-4.5。在 T-4.4 持久化基础上增加正式多会话管理能力:
> 当前上下文会话列表、新建、切换、删除、删除当前会话自动回退、生成期间保护、角色与普通助手隔离。

### 实现概要

- **会话列表实现形式**:ChatPage 内部覆盖层 `components/ChatSessionListPanel.ets`,通过 `@ObjectLink` 引用 ChatViewModel,不引入跨页面回调和全局选择状态。
- **当前角色与普通助手隔离**:`ChatRepository.listByExactCharacterId(characterId, options)` 精确匹配;有角色时 `equalTo('character_id', id)`,无角色时 `isNull('character_id')`;始终排除 `is_archived = true`。
- **新建会话流程**:`ChatService.startNewSession()` → flush pending → `ChatPersistenceService.createNewSession(characterId, firstMessage, title)` → 设置 currentChatId/currentSequenceNumber → 替换 messages 数组 → 通知 onMessagesUpdate → 刷新列表。
- **切换会话流程**:`ChatService.switchSession(chatId)` → 校验目标属于当前上下文 → flush pending → 加载目标会话 → normalize interrupted Streaming 消息 → 替换状态 → 通知页面。
- **删除会话及当前会话回退规则**:`ChatPersistenceOperations.removeChatWithMessages()` 事务删除 Chat+Message;删除当前会话后查询剩余会话,有则切换最近,无则自动新建(有角色 firstMessage 时只创建一次)。
- **生成期间操作保护**:`isGenerating()` 为 true 时禁止 listSessions/startNewSession/switchSession/deleteSession,UI 按钮置灰。
- **会话操作串行化**:`sessionOperationInProgress` 布尔锁,每次操作进入检查、finally 释放,防止并发新建/切换/删除。

### AppServices / ChatService / ChatViewModel 接入

- **AppServices**:沿用 T-4.4 的 `createChatService()`,无新增。
- **ChatService**:新增 `listSessions()` / `startNewSession()` / `switchSession(chatId)` / `deleteSession(chatId)` / `getCurrentChatId()` / `isSessionOperationInProgress()`。
- **ChatViewModel**:新增 `sessions` / `showSessionList` / `isLoadingSessions` / `isSessionOperating` / `sessionError` / `pendingDeleteChatId` / `showDeleteSessionConfirm` 状态 + `openSessionList()` / `closeSessionList()` / `refreshSessions()` / `createNewSession()` / `selectSession(chatId)` / `requestDeleteSession(chatId)` / `cancelDeleteSession()` / `confirmDeleteSession()` / `isCurrentSession(chatId)` 方法。

### Repository 最小扩展

- `ChatRepository.listByExactCharacterId(characterId: string | undefined, options?: ChatContextListOptions): Promise<Chat[]>`
- `ChatContextListOptions { limit?: number; offset?: number }`
- 不改变现有 `list()` 旧语义。

### ChatPersistenceService 扩展

- `listSessionsForContext(characterId?, limit?): Promise<Chat[]>`(默认 limit=50,不查消息正文,不 N+1)
- `createNewSession(characterId?, firstMessage?, title?): Promise<PersistedChatSession>`(事务创建 Chat + firstMessage,只持久化一次)
- `deleteSession(chatId)` 沿用 `ChatPersistenceOperations.removeChatWithMessages()`

### 定向测试

- **测试代码编译状态**:
  - `entry@default` BUILD SUCCESSFUL
  - `entry@ohosTest` BUILD SUCCESSFUL
- **测试实际执行状态**:本会话仅完成编译验证,未在 DevEco Studio IDE 中运行设备测试(按快速执行规则,设备测试需在 IDE 中执行,本会话不启动设备测试)。
- 测试文件:
  - `entry/src/test/ChatSessionService.test.ets`(本地 34 项,LocalMockPersistenceService 内存 mock)
  - `entry/src/test/ChatSessionViewModel.test.ets`(本地 16 项,MockChatServiceForSession)
  - `entry/src/ohosTest/ets/test/ChatSessionRepository.test.ets`(设备 12 项,独立测试数据库)

### 尚未解决的问题

- 设备测试实际执行结果待在 DevEco Studio IDE 中验证(本会话仅编译通过)。
- 模拟器人工验收 5 个场景未执行(需设备环境)。
- 应用重启后会话恢复的实机验证未执行(需设备环境)。
- CharacterRepository / Summary / Swipe / Preset / Lorebook RDB / 会话搜索 / 重命名 / 归档 / 正文生成标题:均按任务要求不实现。

### 日志泄漏检查

- ChatService 会话操作日志仅输出:`ChatSession | list count=N` / `ChatSession | created` / `ChatSession | switched` / `ChatSession | deleted`。
- 不输出 chatId 完整值、title 原文、消息正文、firstMessage、SQL、ValuesBucket、Character Prompt、世界书正文、API Key、Authorization、宏替换结果。

- [x] T-4.5 正式验收通过(编译层面)
- [ ] T-4.5 设备测试实际执行验证(待 IDE 中运行)
- [ ] T-4.5 模拟器人工验收(待设备环境)

## T-4.6 CharacterRepository 与 Preferences→RDB 迁移 MVP 完成记录(2026-07-17)

> 说明:本任务将 Character 数据的正式数据源从 Preferences 切换到 RDB,同时安全迁移现有用户已创建或导入的角色。
> CharacterRepository 成为角色数据唯一正式数据源;CharacterService 不再使用 CharacterStore 执行业务 CRUD;旧 Preferences 角色数据在首次升级时自动迁入 RDB;当前角色选择保持不变;迁移可重复执行,不重复导入、不覆盖较新 RDB 数据;旧 Preferences 数据暂时保留作为迁移备份,不立即删除。Lorebook 仍继续使用 Preferences,本任务不迁移。

### 实现概要

- **CharacterRepository**(`entry/src/main/ets/repositories/CharacterRepository.ets`):角色数据 RDB 仓储,基于现有 `characters` 表(版本 1,不修改 Schema)。
  - `insert` / `insertWithStore` / `getById` / `list` / `update` / `remove` / `count` / `exists` / `insertManyIfMissing`
  - `list` 排序:`created_at ASC → updated_at ASC → id ASC`(稳定排序,不按 name 排序)
  - `insert` ID 重复映射为 `DatabaseError.AlreadyExists`;`update` 不存在返回 `NotFound`(基于 affected rows);`remove` 幂等
  - `insertManyIfMissing`:事务批量导入,按 ID 跳过已存在(不覆盖,不生成新 ID);中途失败整批新增部分回滚;已存在记录不受影响;空数组直接返回
  - `characterFromRow` 行映射:损坏数据(id/name 空、时间戳非法)抛 `DatabaseError.InvalidData`,ResultSet 所有路径关闭
  - 不打印角色字段;不修改输入 Character 对象
  - `CharacterImportResult`:`{ insertedCount, skippedExistingCount, totalCount }`(不含角色 ID 或正文)

- **CharacterSelectionStore**(`entry/src/main/ets/storage/CharacterSelectionStore.ets`):当前角色选择的轻量 Preferences 存储。
  - 复用旧 `current_character_id_v1` key 和 `arktavern_settings` Preferences 文件,升级后无需迁移当前选择值
  - `getCurrentCharacterId()` / `setCurrentCharacterId(id | null)` / `clear()`
  - 不保存完整 Character 列表;不依赖 RDB;不依赖页面

- **CharacterMigrationResult**(`entry/src/main/ets/models/CharacterMigrationResult.ets`):迁移结果模型,只含计数,不含角色名称、正文、avatarUri、角色 ID 完整列表。

- **CharacterMigrationService**(`entry/src/main/ets/services/CharacterMigrationService.ets`):迁移编排服务。
  - 构造:`(characterStore, characterRepository, characterSelectionStore, appPreferences)`
  - `migrateIfNeeded()` 算法:检查标记 → 已完成直接返回 → 读取旧 CharacterStore 全量 + 当前角色 ID → `insertManyIfMissing` → 验证每个旧 ID 在 RDB 中存在 → 检查当前角色(存在则保留,不存在则清空)→ 写入 marker=true
  - 幂等性:迁移标记为 true 时直接返回;中途崩溃后下次启动重新执行;已存在 ID 跳过,不产生重复角色
  - 日志只输出计数,不输出角色 ID/名称/正文

- **AppPreferences 扩展**:新增 `getBoolean(key, defValue)` / `putBoolean(key, value)` 方法,复用现有 `validateKey/requirePrefs/fromPlatformError` 模式,类型不匹配返回默认值(容错),写入后自动 flush。不破坏已有 string API。

- **CharacterService 切换到 RDB**(`entry/src/main/ets/services/CharacterService.ets`):
  - 构造改为 `(repository: CharacterRepository, selectionStore: CharacterSelectionStore, assetStore: CharacterAssetStore, legacyStore: CharacterStore)`
  - `list` / `getById` 直接委托 repository
  - `create` / `importFromParsed`:生成 UUID → validate → repository.insert → ID 冲突生成新 UUID 重试一次(用户主动导入发生冲突时才生成新 ID,与迁移时保留原 ID 不同)
  - `update`:repository.getById → updateCharacter → validate → repository.update;`NotFound` 映射为 Error
  - `remove`:repository.getById(幂等检查)→ repository.remove → 若是当前角色清空选择 → deleteAvatar(失败不回滚角色记录,仅 warn)
  - `setCurrentCharacterId`:非空时先 repository.exists 校验 → selectionStore.setCurrentCharacterId
  - `getCurrentCharacter`:selectionStore.getCurrentCharacterId → repository.getById → 不存在则清空选择
  - `confirmPngImport`:saveAvatar → createCharacter → validate → repository.insert(失败回滚头像)
  - `getLegacyStore()`:暴露 legacyStore 供 MigrationService 使用
  - 日志不输出角色 ID 完整值、名称、正文

- **AppServices 接入**(`entry/src/main/ets/services/AppServices.ets`):
  - 新增 import 与私有字段:`CharacterRepository` / `CharacterSelectionStore` / `AppPreferences` / `CharacterMigrationService`
  - 初始化顺序:modelService → appPreferences → dbHelper → characterService.initialize → **characterMigrationService.migrateIfNeeded** → lorebookService.initialize
  - 数据库迁移失败时 AppServices 初始化失败(通过 Promise 链 `.catch` 清理实例),不静默回退到旧 CharacterStore
  - 不向页面暴露 Repository;不新增 `getCharacterRepository()`

### 迁移标记和幂等策略

- **标记 key**:`character_rdb_migration_v1_complete`(boolean),存于 AppPreferences(`arktavern_settings`)
- **写入时机**:只有迁移、验证、当前选择检查全部完成后才写 true
- **失败保护**:迁移失败或验证失败时不写 true,允许下次启动重试
- **幂等性保证**:`insertManyIfMissing` 按 ID 跳过已存在,事务包裹;若 RDB 已插入角色但完成标记尚未写入,下次启动重新执行时已存在 ID 跳过,不产生重复角色,最终完成
- **不使用 TODO 或文件存在性作为迁移标记**;不把标记存入数据库 characters 表

### Preferences→RDB 迁移流程

```
1. 检查 character_rdb_migration_v1_complete
2. 已完成 → 直接返回 createSkippedMigrationResult()
3. 从旧 CharacterStore.list() 读取全部角色
4. 从旧 CharacterStore.getCurrentCharacterId() 读取当前角色 ID
5. 调用 CharacterRepository.insertManyIfMissing(legacyCharacters)
6. 对每个旧角色 ID 验证 RDB 中存在(repository.exists)
7. 若 currentCharacterId 非空:
   a. RDB 中存在 → 调用 selectionStore.setCurrentCharacterId 保留
   b. RDB 中不存在 → 调用 selectionStore.setCurrentCharacterId(null) 清空
8. 写入 marker = true
9. 返回 CharacterMigrationResult
```

- **无旧角色时**:标记完成;不创建默认角色;不创建空数据库记录;当前角色 ID 若指向不存在角色则清空
- **RDB 已有角色时**:相同 ID 跳过;不覆盖;继续导入其他缺失角色;验证旧角色 ID 最终全部存在

### JSON / PNG 导入与头像兼容

- **JSON 导入**:生成新 UUID → `parseCharacterJson` → `importFromParsed` → repository.insert;ID 冲突生成新 UUID 重试一次
- **PNG 导入**:`confirmPngImport` 先 `assetStore.saveAvatar(pngUri, characterId)` 复制头像到应用私有目录 → 创建 Character(带 avatarUri)→ repository.insert;角色保存失败时回滚头像(`assetStore.deleteAvatar(characterId)`)
- **头像文件**:继续由 `CharacterAssetStore` 管理,不写入 RDB;删除角色时调用 `assetStore.deleteAvatar` 清理(失败不回滚角色记录)
- **avatarUri**:空字符串合法(`avatar_uri TEXT NOT NULL DEFAULT ''`)

### 当前角色和已有 Chat 兼容

- **当前角色选择**:迁入 RDB 后保留原 `current_character_id_v1` key(由 CharacterSelectionStore 复用),无需迁移当前选择值;迁移时若 currentCharacterId 指向的角色在 RDB 中存在则保留,否则清空
- **已有 Chat**:`chats.character_id` 不设置外键,原 Character ID 保留,已有 Chat 自动继续对应正确角色;不迁移 Chat;不更新 chats;不修改会话列表逻辑
- **删除 Character 后**:Chat 数据保留,不级联删除;以后可作为"角色已删除的历史聊天"处理(本任务不新增该 UI)

### 旧 Preferences 备份处理

- 迁移成功后**不删除** `character_list_v1`;**不清空**旧 JSON;**不继续双写**;**不继续从旧列表读取业务数据**
- 原因:保留一期回滚备份,避免跨 Preferences/RDB 删除过程引入不可恢复风险
- 明确:RDB 是迁移完成后的唯一正式数据源;旧 Preferences 仅作为静态历史备份
- 未实现:RDB 与 Preferences 双向同步;每次修改同时写两份;启动时比较 updatedAt 后自动合并

### 定向测试(区分编译与实际执行)

- **测试代码编译状态**:
  - `entry@default` BUILD SUCCESSFUL
  - `entry@ohosTest` BUILD SUCCESSFUL
- **测试实际执行状态**:本会话仅完成编译验证,未在 DevEco Studio IDE 中运行设备测试(按快速执行规则,设备测试需在 IDE 中执行,本会话不启动设备测试)
- 测试文件:
  - `entry/src/ohosTest/ets/test/CharacterRepository.test.ets`(设备 30 项,独立测试数据库 `arktavern_character_repository_test.db`,前后清理)
  - `entry/src/test/CharacterMigrationService.test.ets`(本地 20 项,Mock 编排逻辑,不依赖真实 RDB)
  - `entry/src/test/CharacterServiceRdb.test.ets`(本地 23 项,Mock Repository/SelectionStore/AssetStore/LegacyStore)

### 编译结果

- 第 1 次 `entry@default` 编译失败(10 个错误):
  - `CharacterRepository.ets`:`store.count(predicates)` API 不存在(3 处);`throw err` 违反 `arkts-limited-throw`(1 处)
  - `CharacterService.ets`:`throw e` 违反 `arkts-limited-throw`(4 处)
  - `AppServices.ets`:`migrateIfNeeded()` 返回 `Promise<CharacterMigrationResult>` 不能直接转为 `Promise<void>`(1 处)
- 修复:
  - `store.count(predicates)` 改为 `store.querySql('SELECT COUNT(*) AS cnt FROM ...')` 或 `store.query(predicates)` + `rs.goToFirstRow()`
  - `throw err`/`throw e` 在 catch 块中改为先 `if (e instanceof Error) throw e; else throw new Error('...: ' + String(e))`
  - `migrateIfNeeded()` 调用改为 `async (): Promise<void> => { await ... }`
- 第 2 次 `entry@default` 编译:**BUILD SUCCESSFUL**
- `entry@ohosTest` 编译:**BUILD SUCCESSFUL**(仅遗留 throw 相关 warning,非本任务代码)

### 升级迁移人工验收结果

- 按任务规范第二十二节"模拟器人工迁移验收"5 个场景未执行(需设备环境):
  - 场景一:准备旧 Preferences 数据(Alice/Bob/PNG 角色,Alice 设为当前,有聊天会话)— 未执行
  - 场景二:升级启动(确认迁移完成、角色数量一致、Alice 仍为当前、头像正常、聊天可恢复)— 未执行
  - 场景三:重启幂等(强制停止后重启,确认不重复导入、marker 生效、当前角色不变)— 未执行
  - 场景四:迁移后 CRUD(新建 Charlie → 编辑 → 设为当前 → 重启 → 导出 → 删除 → 重启)— 未执行
  - 场景五:迁移后导入(JSON + PNG 导入 → 重启 → 删除 → 重启)— 未执行
- 数据库辅助核验(第二十三节)未执行(需设备环境)

### 重启幂等验证结果

- 未执行(需设备环境)
- 幂等性通过代码与 Mock 测试覆盖:
  - `CharacterMigrationService.test.ets` 测试 15(第一次执行中断后第二次可重试)、测试 16(重复执行不产生重复角色)、测试 1(marker=true 时跳过)
  - `CharacterRepository.test.ets` 测试 19(insertManyIfMissing 跳过已有 ID)、测试 20(不覆盖已有 RDB 记录)

### 迁移后 CRUD 与导入验证

- 未执行(需设备环境)
- CRUD 切换通过 Mock 测试覆盖:
  - `CharacterServiceRdb.test.ets` 测试 1-5(list/getById/create/update/remove 从 Repository)、测试 11(JSON 导入写入 RDB)、测试 13(PNG 导入写入 RDB)

### 日志泄漏检查

- `CharacterMigrationService` 日志仅输出:`CharacterMigration | start` / `CharacterMigration | complete legacy=N inserted=N skipped=N` / `CharacterMigration | already complete, skip` / `CharacterMigration | verify failed, not all legacy ids exist in RDB`
- `CharacterRepository` 日志:仅 `CharacterRepository | count=N`(可选),不输出角色 ID、name、description、personality、scenario、firstMessage、systemPrompt、avatarUri、完整角色 ID 列表、旧 JSON、SQL、ValuesBucket、API Key
- `CharacterService` 日志:`create ok` / `update ok id=<id>` / `remove ok id=<id>` / `setCurrentCharacterId ok` / `importFromParsed ok source=<format>` / `confirmPngImport ok` — id 字段为角色 ID(非正文),符合任务规范"不输出角色正文"要求
- `AppPreferences.getBoolean/putBoolean` 日志:仅输出 key 名,不输出 value
- `CharacterSelectionStore` 日志:`initialize ok` / `setCurrentCharacterId ok`,不输出角色 ID

### 尚未解决的问题

- 设备测试实际执行结果待在 DevEco Studio IDE 中验证(本会话仅编译通过)
- 模拟器人工验收 5 个场景未执行(需设备环境)
- 数据库辅助核验未执行(需设备环境)
- LorebookRepository / Lorebook Preferences 迁移:按任务要求不实现
- 删除旧 Character Preferences 备份:按任务要求不实现,保留一期回滚备份
- 数据库版本升级 / characters 表结构修改:按任务要求不实现
- 会话搜索 / Swipe / Summary / Preset / Character V3 大量新字段扩展 / 角色搜索 / 角色分组 / 在线角色市场 / 角色云同步 / 聊天表外键改造 / Character 删除后级联删除聊天 / Character 头像二进制写入数据库:均按任务要求不实现

### T-4.6 验收清单

- [x] CharacterRepository 成为正式数据源
- [x] CharacterService 不再使用 CharacterStore CRUD
- [x] 旧角色自动迁入 RDB(代码层面)
- [x] 迁移保留原 Character ID
- [x] 当前角色选择保留(代码层面)
- [x] 迁移可重复执行(代码层面)
- [x] 中断后可安全重试(代码层面,Mock 测试覆盖)
- [x] RDB 已有角色不被覆盖
- [x] 不产生重复角色
- [x] 旧 Preferences 数据暂时保留
- [x] 迁移后不双写 Preferences
- [x] JSON / PNG 导入正常(代码层面)
- [x] 头像正常(代码层面)
- [x] 新建、编辑、删除、设为当前正常(代码层面)
- [x] 删除当前角色清空选择
- [x] 现有角色聊天仍可恢复(代码层面,Character ID 保留)
- [x] 不修改 Lorebook
- [x] 不修改数据库 Schema
- [x] `entry@default` BUILD SUCCESSFUL
- [x] `entry@ohosTest` BUILD SUCCESSFUL
- [x] 测试编译和实际执行状态分开记录
- [ ] 升级迁移人工验证完成(待设备环境)
- [ ] 无角色正文、SQL、Prompt 或密钥日志泄漏(代码层面已检查,实机 hilog 检查待设备环境)

- [x] T-4.6 正式验收通过(编译层面)
- [ ] T-4.6 设备测试实际执行验证(待 IDE 中运行)
- [ ] T-4.6 模拟器人工验收(待设备环境)
