# T-3D.6D 模型导入稳定性、兼容性诊断与自动验收

继续开发 HarmonyOS NEXT 原生项目 ArkTavern。

项目路径：

D:\DevEco_studio\ArkTavern

用户当前不在电脑前，本任务允许 Agent 在不需要用户交互的前提下，自主执行：

- 阅读项目文档；
- 分析源码；
- 修改代码；
- 构建；
- 安装；
- 启动应用；
- 使用已连接真机；
- 使用可用模拟器；
- 收集 hilog；
- 创建和运行自动化测试；
- 创建 Debug-only 测试入口；
- 自动导入测试模型；
- 自动生成损坏模型；
- 自动验证导入结果；
- 自动清理测试代码；
- 更新 TODO.md。

不得因为一个普通问题立即停下来询问用户。

先自行调查、尝试修复、重新构建和验证。

只有以下情况才允许停止并报告：

1. 存在无法安全解决的 Git 冲突；
2. 必须获取用户账号、密码、证书或外部服务凭据；
3. 需要用户提供当前项目中完全不存在的关键模型文件；
4. 真机、模拟器和本地 host 测试全部不可用；
5. 连续两次确认属于 DevEco 或系统环境故障，而不是项目代码问题；
6. 修改可能破坏用户未提交的重要代码，且无法通过局部方案规避。

不得把普通编译错误、API 不熟悉、路径问题、HAP 安装失败、设备短暂断连、测试数据不足作为立即停止理由。

完成本任务后停止，不进入完整模型查看器。

────────────────────────────────
一、总体目标
────────────────────────────────

本任务完成以下能力：

1. 模型导入前结构扫描；
2. GLB 容器严格校验；
3. glTF JSON 语义校验；
4. 扩展兼容性分析；
5. meshopt 转换链路稳定化；
6. KHR_mesh_quantization 兼容策略；
7. 材质、纹理、动画、骨骼、Morph 信息分析；
8. 模型重复导入检测；
9. 转换缓存一致性；
10. 导入失败的精确诊断；
11. 模型导入后的自动取景；
12. 异常尺寸和原点偏移检测；
13. 导入进度状态；
14. 取消和失败清理；
15. 模型导入自动化测试矩阵；
16. 真机或模拟器验收；
17. TODO.md 完成记录。

当前核心原则：

- 不把“ArkGraphics 加载失败”当作单一错误；
- 不只验证 Grace 一个模型；
- 不依赖用户手动点击完成验收；
- 不直接复制数据库文件；
- 不修改聊天数据库结构；
- 不修改动作系统业务；
- 不进入完整独立模型查看器；
- 不重新破坏已完成的 meshopt 正向链路；
- 不退回错误的 GLB chunk 对齐逻辑。

重要规范：

GLB 中 chunkLength 表示 chunkData 的长度。

JSON 和 BIN 的 padding 属于 chunkData。

因此：

- Writer 必须写入包含 padding 后的 chunkLength；
- Reader 读取 chunkLength 后不得再次自行 alignUp 跳过额外 padding；
- chunkLength 应满足 4 字节对齐；
- chunk 起始与结束均应 4 字节对齐。

不得恢复以下错误实现：

- chunkLength 写原始 JSON 长度；
- 物理写入 padded JSON；
- Reader 读取后再手动跳 padding。

────────────────────────────────
二、开始前必须执行
────────────────────────────────

依次执行：

1. 阅读 AGENTS.md；
2. 阅读 project_memory.md；
3. 阅读 TODO.md 中：
   - T-3D.6C；
   - T-3D.6C-C3；
   - T-3D.5D；
   - 所有模型导入、meshopt、GLB、ArkGraphics 相关记录；
4. 执行 git status；
5. 记录所有已有未提交修改；
6. 不覆盖不属于本任务的用户修改；
7. 找出模型导入完整调用链；
8. 找出模型数据库或配置存储方式；
9. 找出文件选择器与沙箱复制实现；
10. 找出模型缓存目录与临时目录；
11. 找出 ArkGraphics 加载入口；
12. 找出 Bounds、相机、baseFitScale 计算入口；
13. 找出已有 NAPI meshopt 解码器；
14. 找出已有 GLB Reader、Writer、Validator；
15. 找出模型列表与动作管理页展示模型信息的代码；
16. 找出已有单元测试和 ohosTest 入口；
17. 检查当前是否存在已连接设备；
18. 检查是否存在可启动模拟器；
19. 检查 hdc 连接状态；
20. 检查 DevEco 构建工具可用性。

生成内部工作清单，但不要创建无关文档。

不得：

- git reset；
- git checkout -- 用户修改文件；
- git stash；
- clean 整个仓库；
- 删除用户模型；
- 删除现有有效缓存；
- 修改签名配置；
- 修改应用包名；
- 修改聊天数据；
- 修改角色卡格式；
- 修改已完成的聊天导入导出。

────────────────────────────────
三、先绘制真实导入调用链
────────────────────────────────

必须从源码确认真实调用链。

建议整理为：

系统文件选择器
→ URI / fd
→ 沙箱复制
→ 文件指纹
→ 原始文件验证
→ GLB 容器扫描
→ glTF JSON 解析
→ 扩展扫描
→ 兼容性判定
→ 是否需要 meshopt 转换
→ meshopt 解码
→ 标准 GLB Writer
→ 转换后 GLB 再验证
→ ArkGraphics 加载
→ Scene 创建
→ Bounds 计算
→ baseFitScale
→ Camera / Transform
→ 模型记录持久化
→ 模型列表刷新

分别指出：

- 哪些步骤在 ArkTS；
- 哪些步骤在 C++ NAPI；
- 哪些步骤在 ArkGraphics；
- 哪些步骤可能产生缓存；
- 哪些步骤可能产生数据库记录；
- 哪些步骤失败后需要回滚。

如果实际调用链不同，以项目源码为准。

完成调用链确认后再修改。

────────────────────────────────
四、建立统一导入结果模型
────────────────────────────────

新增或完善统一结果类型。

建议：

enum ModelImportStage {
  Idle,
  SelectingFile,
  CopyingFile,
  HashingFile,
  ValidatingContainer,
  ParsingJson,
  InspectingExtensions,
  CheckingCompatibility,
  DecodingMeshopt,
  RebuildingGlb,
  ValidatingConvertedGlb,
  LoadingScene,
  ComputingBounds,
  CreatingPreview,
  PersistingRecord,
  Completed,
  Cancelled,
  Failed
}

enum ModelCompatibilityLevel {
  FullySupported,
  SupportedAfterConversion,
  PartiallySupported,
  DisplayOnly,
  Unsupported,
  Corrupted
}

enum ModelImportErrorCode {
  UserCancelled,
  FileOpenFailed,
  FileReadFailed,
  FileTooSmall,
  InvalidGlbMagic,
  UnsupportedGlbVersion,
  InvalidDeclaredLength,
  InvalidChunkAlignment,
  MissingJsonChunk,
  InvalidJsonChunkType,
  JsonParseFailed,
  MissingAssetVersion,
  UnsupportedGltfVersion,
  MissingBuffer,
  MissingBinChunk,
  BufferLengthMismatch,
  BufferViewOutOfRange,
  AccessorOutOfRange,
  SparseAccessorInvalid,
  MeshPrimitiveInvalid,
  IndexAccessorInvalid,
  ImageDataInvalid,
  UnsupportedImageFormat,
  TextureReferenceInvalid,
  MaterialReferenceInvalid,
  MeshoptMetadataInvalid,
  MeshoptDecodeFailed,
  ConvertedGlbInvalid,
  UnsupportedRequiredExtension,
  ArkGraphicsParseFailed,
  SceneCreationFailed,
  EmptyScene,
  InvalidBounds,
  ModelNotVisible,
  MemoryInsufficient,
  CacheWriteFailed,
  DatabaseWriteFailed,
  CancelledDuringImport,
  Unknown
}

统一返回：

interface ModelImportResult {
  success: boolean;
  stage: ModelImportStage;
  compatibility: ModelCompatibilityLevel;
  errorCode?: ModelImportErrorCode;
  userMessage: string;
  diagnosticMessage?: string;
  modelInfo?: ModelInspectionResult;
  sourceSha256?: string;
  cachedPath?: string;
  converted: boolean;
  warnings: string[];
}

禁止不同页面各自拼接错误文本。

所有用户提示必须从统一错误映射生成。

────────────────────────────────
五、建立 ModelInspectionResult
────────────────────────────────

导入前扫描结果至少包含：

interface ModelInspectionResult {
  format: 'glb' | 'gltf' | 'unknown';
  glbVersion?: number;
  gltfVersion?: string;
  fileSizeBytes: number;

  sceneCount: number;
  nodeCount: number;
  meshCount: number;
  primitiveCount: number;
  materialCount: number;
  textureCount: number;
  imageCount: number;
  samplerCount: number;

  animationCount: number;
  skinCount: number;
  jointCount: number;
  morphTargetCount: number;
  cameraCount: number;
  lightCount: number;

  accessorCount: number;
  bufferViewCount: number;
  bufferCount: number;

  usedExtensions: string[];
  requiredExtensions: string[];
  directlySupportedExtensions: string[];
  convertibleExtensions: string[];
  unsupportedExtensions: string[];

  hasMeshopt: boolean;
  hasMeshQuantization: boolean;
  hasDraco: boolean;
  hasExternalBuffers: boolean;
  hasExternalImages: boolean;
  hasEmbeddedImages: boolean;
  hasTransparentMaterials: boolean;
  hasUnlitMaterials: boolean;
  hasPbrMaterials: boolean;

  declaredBinLength?: number;
  actualBinLength?: number;

  warnings: string[];
}

只统计真实存在的数据。

不得凭文件名猜测模型类型。

────────────────────────────────
六、GLB 容器严格校验
────────────────────────────────

完善独立的 GlbContainerValidator。

必须校验：

1. 文件至少 12 字节；
2. magic 为 glTF；
3. version 为 2；
4. header.length 等于实际文件长度；
5. 第一个 chunk 必须为 JSON；
6. JSON chunkLength 大于 0；
7. JSON chunkLength 为 4 的倍数；
8. JSON chunk 数据不越界；
9. JSON chunk 结尾 padding 合法：
   - 空格 0x20；
   - 必要时兼容项目已有标准；
10. 第二个 chunk 如存在应为 BIN；
11. BIN chunkLength 为 4 的倍数；
12. BIN chunk 不越界；
13. chunk 之间无非法空洞；
14. 文件末尾无未声明额外数据；
15. 不允许整数溢出；
16. 所有 offset + length 使用安全加法；
17. 不允许 0xFFFFFFFF 等恶意长度导致越界；
18. chunk 数量异常时明确报告；
19. 多余未知 chunk 要么安全忽略并警告，要么按 glTF 规范拒绝；
20. 不得 crash。

Reader 不得读取 chunkLength 后再 alignUp。

Writer 必须写 padded chunkLength。

增加独立测试：

- 正常单 JSON；
- 正常 JSON + BIN；
- header 截断；
- magic 错误；
- version 错误；
- declared length 小于实际；
- declared length 大于实际；
- JSON chunkLength 非 4 对齐；
- JSON 越界；
- 第一个 chunk 不是 JSON；
- BIN 越界；
- chunkLength = 0xFFFFFFFF；
- 文件末尾多余数据；
- 空 JSON；
- JSON padding 错误。

────────────────────────────────
七、glTF JSON 语义校验
────────────────────────────────

容器有效不代表 glTF 有效。

增加 GltfSemanticValidator。

至少校验：

1. asset 存在；
2. asset.version 为 2.0；
3. buffers 数组合法；
4. GLB 中 buffer[0].uri 通常不应引用外部文件；
5. buffer.byteLength 不超过实际 BIN；
6. bufferViews 的：
   - buffer；
   - byteOffset；
   - byteLength；
   - byteStride；
   均合法；
7. accessors 的：
   - bufferView；
   - byteOffset；
   - componentType；
   - count；
   - type；
   - normalized；
   均合法；
8. accessor 所需字节范围不越界；
9. MAT2、MAT3、MAT4 对齐规则；
10. sparse accessor 结构合法；
11. mesh primitive attributes 合法；
12. POSITION accessor 必须存在于可渲染 primitive；
13. indices accessor 类型合法；
14. mode 在支持范围；
15. materials 引用合法；
16. textures、images、samplers 引用合法；
17. nodes children 引用合法；
18. scene.nodes 引用合法；
19. skin.joints 引用合法；
20. animation sampler、channel 引用合法；
21. morph target accessor 引用合法；
22. extension 对象结构至少完成必要字段检查；
23. 不得因未知可选字段 crash；
24. 未知 required extension 必须判定不支持；
25. 未知 used extension可以警告但不能直接当 required。

所有数组索引必须显式边界检查。

禁止直接使用未经验证的 JSON 字段索引数组。

────────────────────────────────
八、扩展兼容矩阵
────────────────────────────────

建立集中配置：

ModelExtensionCompatibilityRegistry

至少区分：

## 直接支持

根据 ArkGraphics 当前真实能力确认，不得猜测。

可能包括：

- KHR_materials_unlit；
- KHR_texture_transform；
- KHR_lights_punctual；
- 其他 ArkGraphics 已验证扩展。

## 可转换

至少：

- EXT_meshopt_compression。

## 可保留

- KHR_mesh_quantization。

如果 meshopt 解码后 accessor 仍依赖量化 componentType：

只要 ArkGraphics 支持或标准 glTF 允许，就保留该扩展。

不得无依据删除 KHR_mesh_quantization。

## 暂不支持

例如：

- KHR_draco_mesh_compression；
- 未实现的纹理压缩；
- 未实现的材质扩展；
- 未实现的 vendor extension。

必须根据 requiredExtensions 判断：

- 如果扩展仅在 extensionsUsed 中但不是 required：
  可以继续导入并警告；
- 如果在 extensionsRequired 中且既不直接支持也不能转换：
  必须拒绝，并列出扩展名称。

兼容性报告必须分别输出：

- 文件格式兼容；
- 几何兼容；
- 材质兼容；
- 纹理兼容；
- 骨骼兼容；
- 动画兼容；
- 动作重定向兼容。

不得只显示一个模糊的“部分人形”。

────────────────────────────────
九、meshopt 转换稳定化
────────────────────────────────

检查现有 meshopt 解码链路：

- EXT_meshopt_compression；
- buffer；
- byteOffset；
- byteLength；
- byteStride；
- count；
- mode；
- filter。

必须校验：

1. buffer 索引合法；
2. 压缩范围不越界；
3. byteStride 合法；
4. count 合法；
5. 解码后大小使用安全乘法；
6. 解码后输出长度准确；
7. mode 支持；
8. filter 支持；
9. NAPI 返回错误码明确；
10. C++ 异常不跨 NAPI；
11. 内存分配失败明确报告；
12. 解码失败不写半成品；
13. 多个 meshopt bufferView 全部处理；
14. 解码后更新 bufferView；
15. 移除 EXT_meshopt_compression 元数据；
16. extensionsUsed 中按实际情况移除；
17. extensionsRequired 中按实际情况移除；
18. 保留其他无关扩展；
19. 重新构建 BIN；
20. 正确更新 buffer.byteLength；
21. JSON padded chunkLength 正确；
22. BIN padded chunkLength 正确；
23. 输出标准 GLB；
24. 输出后立即运行容器和语义校验。

禁止在转换后直接交给 ArkGraphics 而不验证。

如果转换失败：

- 删除临时输出；
- 不覆盖已有有效缓存；
- 不创建模型数据库记录；
- 返回具体错误。

────────────────────────────────
十、转换缓存
────────────────────────────────

建立或完善模型缓存策略。

缓存 key 至少包含：

- source SHA-256；
- converter schema version；
- meshopt decoder version；
- app model pipeline version。

例如：

cacheKey =
sha256(sourceBytes)
+ pipelineVersion
+ converterVersion

不得只用文件名。

缓存 metadata 至少包含：

- sourceSha256；
- sourceSize；
- sourceLastModified，如可获得；
- pipelineVersion；
- convertedAt；
- convertedFileSize；
- convertedSha256；
- validationPassed；
- ArkGraphicsLoadPassed；
- usedExtensions；
- warnings。

读取缓存前必须验证：

1. metadata 存在；
2. source SHA-256 一致；
3. pipelineVersion 一致；
4. 输出文件存在；
5. 输出文件大小合理；
6. 输出 GLB 容器有效；
7. 必要时 converted SHA-256 一致。

如果缓存文件损坏：

- 删除坏缓存；
- 重新转换；
- 不反复加载坏文件。

如果 ArkGraphics 对缓存加载失败：

- 标记缓存失效；
- 删除或隔离；
- 重新转换一次；
- 仍失败则报告，不无限重试。

最大自动重试：

1 次。

────────────────────────────────
十一、重复导入检测
────────────────────────────────

导入原文件后计算 SHA-256。

模型记录保存：

- sourceSha256；
- normalizedSha256；
- convertedSha256；
- originalName；
- fileSize；
- importedAt。

重复判断优先使用：

sourceSha256。

如果同一文件已经导入：

显示或自动处理策略：

- 默认不重复复制；
- 复用已有模型记录或提示已存在；
- 如果用户明确允许重复，创建新的逻辑引用，但复用文件缓存；
- 不产生多个相同物理文件。

自动测试中：

- 导入同一模型两次；
- 检查不重复创建转换文件；
- 检查不重复执行 meshopt 解码；
- 检查数据库记录策略符合项目设计。

不得只根据文件名去重。

────────────────────────────────
十二、文件类型支持范围
────────────────────────────────

本任务必须明确支持范围。

至少：

## GLB

作为主要正式支持格式。

## glTF

如果当前项目文件选择器允许选择 .gltf：

先分析当前是否支持外部资源。

如果不支持：

- 不要假装支持；
- 明确提示：
  当前版本仅支持单文件 GLB，暂不支持引用外部 .bin 或纹理的 glTF；
- 或实现受控多文件导入，但只有在工作量可控且不会破坏主任务时才做。

本轮不要求强制完成多文件 glTF。

如果 glTF 使用 data URI 嵌入资源：

可作为可选支持项分析。

不得错误地把所有 .json 当模型导入。

────────────────────────────────
十三、图片和纹理检查
────────────────────────────────

扫描 images：

- uri；
- bufferView；
- mimeType。

检查：

1. uri 与 bufferView 不能同时非法；
2. bufferView 引用合法；
3. mimeType 与内容尽量一致；
4. PNG；
5. JPEG；
6. WebP；
7. KTX2；
8. 其他格式。

根据 ArkGraphics 实际能力分类：

- 支持；
- 可能支持；
- 不支持。

如果纹理格式不支持但几何可显示：

兼容性判定为：

PartiallySupported
或
DisplayOnly

并明确警告：

模型可显示，但部分纹理可能缺失。

不得因为一张非关键纹理失败就把所有错误都显示为“GLB 损坏”。

如果图片数据越界：

判定文件损坏。

────────────────────────────────
十四、材质分析
────────────────────────────────

分析：

- pbrMetallicRoughness；
- baseColorTexture；
- metallicRoughnessTexture；
- normalTexture；
- occlusionTexture；
- emissiveTexture；
- alphaMode；
- alphaCutoff；
- doubleSided；
- unlit；
- 材质扩展。

输出：

- PBR 材质数量；
- 透明材质数量；
- 双面材质数量；
- unlit 材质数量；
- 使用未知材质扩展数量。

透明材质重点检查：

- alphaMode = BLEND；
- alphaMode = MASK；
- alphaCutoff；
- baseColorFactor alpha。

不要在导入阶段改写用户材质。

只做兼容性报告和必要转换。

────────────────────────────────
十五、动画、骨骼和 Morph 分析
────────────────────────────────

导入扫描必须统计：

## Animation

- animationCount；
- samplerCount；
- channelCount；
- translation channel；
- rotation channel；
- scale channel；
- weights channel；
- interpolation：
  - LINEAR；
  - STEP；
  - CUBICSPLINE。

## Skin

- skinCount；
- joints 数；
- inverseBindMatrices；
- skeleton root；
- 最大 joint 数；
- joint 引用合法性。

## Morph

- morphTargetCount；
- POSITION；
- NORMAL；
- TANGENT；
- weights。

这一步只做导入兼容检查。

不得在本任务中实现完整动画播放器或重定向系统。

模型信息页面应能显示：

- 动画数量；
- 骨骼数量；
- Morph 数量；
- 是否存在 skin；
- 是否可作为人形动作模型。

“骨骼未知”应尽可能替换成真实统计。

如果无法判断人形骨骼：

显示：

骨骼：X 个关节
人形兼容：未评估

不要显示“未知”掩盖可统计数据。

────────────────────────────────
十六、自动取景
────────────────────────────────

导入成功但看不到模型时，必须区分格式失败和取景失败。

Scene 加载后：

1. 获取所有可渲染节点；
2. 合并世界空间 Bounds；
3. 检查 min/max 为有限值；
4. 计算 center；
5. 计算 size；
6. 计算 radius；
7. 检查空 Bounds；
8. 检查极端尺寸；
9. 计算 baseFitScale；
10. 设置初始 offset；
11. 设置相机朝向；
12. 设置合理 cameraDistance；
13. 更新 near/far，如 API 支持；
14. 验证模型投影后理论上在视野中。

异常分类：

- EmptyScene；
- NoRenderableMesh；
- InvalidBounds；
- ExtremelySmallModel；
- ExtremelyLargeModel；
- OriginFarFromGeometry；
- ModelOutsideCamera；
- CameraInsideModel。

如果原点远离几何中心：

不要直接修改模型文件。

使用 viewer root transform 进行居中。

保存：

modelCenter
modelRadius
originalBounds
fitScale

模型切换时重新计算。

────────────────────────────────
十七、极端尺寸检测
────────────────────────────────

定义合理但可配置阈值。

例如：

- radius <= 1e-8：异常小；
- radius >= 1e8：异常大；
- center length / radius 过大：原点偏移明显。

具体阈值根据项目世界坐标确定。

不要盲目使用固定数值。

输出警告：

- 模型尺寸极小，已自动适配；
- 模型尺寸极大，已自动适配；
- 模型原点距离几何中心较远，查看时已自动居中。

不得因为模型尺寸异常而拒绝导入，只要数值仍有限且可适配。

────────────────────────────────
十八、导入进度
────────────────────────────────

统一显示当前阶段：

- 正在读取模型；
- 正在校验 GLB；
- 正在分析模型结构；
- 正在检查兼容性；
- 正在解码 meshopt；
- 正在生成标准 GLB；
- 正在验证转换结果；
- 正在加载 3D 场景；
- 正在计算模型边界；
- 正在生成预览；
- 正在保存模型；
- 导入完成。

进度可使用阶段权重：

读取文件：0～10%
容器校验：10～20%
JSON 分析：20～35%
兼容检查：35～45%
meshopt 转换：45～70%
ArkGraphics 加载：70～85%
Bounds 和预览：85～95%
持久化：95～100%

如果无法获得内部细粒度进度，显示阶段，不伪造精确百分比。

────────────────────────────────
十九、取消机制
────────────────────────────────

用户取消后：

- 设置 cancellation token；
- 不开始新的阶段；
- 当前不可中断的 NAPI 调用完成后立即停止；
- 删除临时文件；
- 不创建模型记录；
- 不刷新模型列表；
- 不保留半成品；
- 不删除已有有效缓存；
- 返回 Cancelled。

如果取消发生在数据库写入前：

直接清理。

如果取消发生在事务中：

回滚。

不得显示“导入失败”。

显示：

已取消导入。

Debug 自动测试中增加取消测试。

────────────────────────────────
二十、事务和回滚
────────────────────────────────

如果模型记录保存在数据库或 Preferences：

持久化必须最后执行。

顺序：

文件复制
→ 验证
→ 转换
→ ArkGraphics 加载验证
→ Bounds
→ 预览
→ 保存模型记录

只有所有必要阶段成功后才保存模型记录。

如果保存失败：

- 删除本次新建文件；
- 保留共享缓存时需确认没有其他模型引用；
- 返回 DatabaseWriteFailed；
- 不出现模型列表幽灵条目。

删除模型时：

- 删除记录；
- 检查缓存引用数；
- 无其他引用时才删除物理缓存。

────────────────────────────────
二十一、诊断摘要
────────────────────────────────

新增可复制诊断摘要。

内容包括：

- appVersion；
- pipelineVersion；
- sourceHash 前 8 位；
- fileSize；
- format；
- glbVersion；
- gltfVersion；
- meshCount；
- materialCount；
- animationCount；
- skinCount；
- morphTargetCount；
- extensionsUsed；
- extensionsRequired；
- compatibility；
- converted；
- failingStage；
- errorCode；
- warnings；
- ArkGraphics 错误摘要；
- device model；
- HarmonyOS 版本；
- timestamp。

禁止包含：

- 用户完整绝对路径；
- 用户真实目录；
- 完整消息内容；
- API Key；
- Token；
- 角色聊天；
- 模型完整 JSON；
- 大段二进制数据。

文件名可以保留经过清洗的 basename。

诊断摘要应有：

复制诊断信息

按钮或内部能力。

本任务只需在合适页面接入，不要大改 UI。

────────────────────────────────
二十二、错误提示
────────────────────────────────

用户错误提示必须明确。

示例：

### InvalidGlbMagic

这不是有效的 GLB 文件。

### MissingJsonChunk

GLB 缺少必须的 JSON 数据块。

### MeshoptDecodeFailed

模型使用 meshopt 压缩，但解码失败。文件可能损坏或使用了当前版本不支持的压缩参数。

### UnsupportedRequiredExtension

模型要求当前版本不支持的扩展：KHR_draco_mesh_compression。

### ArkGraphicsParseFailed

模型结构检查通过，但系统 3D 引擎无法解析该模型。

### InvalidBounds

模型已加载，但未得到有效的几何边界，暂时无法显示。

### UnsupportedImageFormat

模型包含当前系统不支持的纹理格式，几何可能可以显示。

错误页面至少提供：

- 关闭；
- 查看详情；
- 复制诊断信息。

不要只显示：

导入失败。

────────────────────────────────
二十三、自动测试模型来源
────────────────────────────────

优先使用已有测试模型：

D:\DevEco_studio\ArkTavern\test_models\Grace Ashcroft - Lying Pose Mobile.glb

先确认文件存在。

不得假设 rawfile 中仍有模型。

允许 Agent 扫描：

D:\DevEco_studio\ArkTavern\test_models

列出可用：

- .glb；
- .gltf；
- .bin；
- 纹理文件。

不得扫描整个用户磁盘。

如果目录中只有 Grace：

使用 Grace 生成派生测试文件。

允许通过 host-side 测试脚本生成：

1. 正常未压缩小 GLB；
2. header 截断 GLB；
3. magic 错误 GLB；
4. version 错误 GLB；
5. length 错误 GLB；
6. JSON chunk 非 4 对齐 GLB；
7. JSON chunk 越界 GLB；
8. 第一个 chunk 为 BIN 的 GLB；
9. BIN chunk 越界 GLB；
10. chunkLength = 0xFFFFFFFF；
11. JSON 非法；
12. asset.version 错误；
13. bufferView 越界；
14. accessor 越界；
15. required extension 不支持；
16. 无 mesh 的空场景；
17. 极小坐标模型；
18. 极大坐标模型；
19. 原点远离几何模型；
20. 同一个模型的重复副本。

生成文件放在：

test_models/generated

或项目已有测试目录。

不得加入正式 rawfile。

测试完成后：

- 保留必要的自动化测试 fixture；
- 删除超大临时文件；
- 不把用户模型复制进源码资源。

────────────────────────────────
二十四、Host-side 验证工具
────────────────────────────────

如果现有 ArkTS 测试难以覆盖二进制 GLB：

允许新增 host-side 验证脚本。

建议放在：

tools/model_import_validation

功能：

- 读取 GLB；
- 输出 header；
- 输出 chunk；
- 验证 chunk 对齐；
- 提取 JSON；
- 扫描扩展；
- 生成损坏 fixture；
- 对转换前后 GLB 做结构比较；
- 计算 SHA-256。

脚本只用于开发测试。

不得成为正式应用运行依赖。

优先使用项目现有语言和工具。

如果使用 Python：

- 只使用标准库；
- 不引入网络依赖；
- 不安装第三方包；
- 提供可直接运行命令；
- 输出简洁。

但如果 AGENTS.md 禁止新增脚本，遵循项目规则。

────────────────────────────────
二十五、单元测试
────────────────────────────────

至少覆盖：

## GLB 容器

1. 正常 GLB；
2. 文件小于 12 字节；
3. magic 错误；
4. version 错误；
5. declared length 错误；
6. JSON chunk 缺失；
7. JSON chunk 类型错误；
8. JSON chunk 非 4 对齐；
9. JSON chunk 越界；
10. BIN chunk 越界；
11. 0xFFFFFFFF 长度；
12. 多余尾部数据。

## glTF 语义

13. asset 缺失；
14. asset.version 错误；
15. bufferView 越界；
16. accessor 越界；
17. accessor componentType 错误；
18. primitive 缺 POSITION；
19. indices 类型错误；
20. node 引用越界；
21. skin joint 越界；
22. animation sampler 引用越界；
23. image bufferView 越界；
24. required extension 不支持。

## meshopt

25. 正常 meshopt；
26. meshopt buffer 越界；
27. byteStride 错误；
28. count 过大；
29. mode 不支持；
30. filter 不支持；
31. 解码输出长度错误；
32. 多 bufferView；
33. 转换后 extensions 清理；
34. 转换后 GLB 再验证。

## 缓存

35. 首次转换；
36. 第二次命中缓存；
37. source hash 改变后失效；
38. pipelineVersion 改变后失效；
39. 缓存文件损坏后重建；
40. ArkGraphics 加载失败后缓存失效。

## 重复导入

41. 同文件导入两次；
42. 同内容不同文件名；
43. 同文件名不同内容；
44. 复用缓存；
45. 数据库记录策略。

## Bounds

46. 正常 Bounds；
47. 空场景；
48. 无 Mesh；
49. NaN Bounds；
50. 极小模型；
51. 极大模型；
52. 原点偏移；
53. 自动居中；
54. baseFitScale 有限；
55. zoomFactor 与 baseFitScale 分离。

## 取消和回滚

56. 读取阶段取消；
57. 转换阶段取消；
58. ArkGraphics 加载前取消；
59. 数据库写入失败；
60. 临时文件清理。

────────────────────────────────
二十六、集成测试矩阵
────────────────────────────────

建立至少以下矩阵：

| 类型 | 预期 |
| 标准 GLB | 直接导入 |
| meshopt GLB | 转换后导入 |
| meshopt + quantization | 转换并保留量化兼容 |
| 带 PBR 材质 | 导入并统计 |
| 带透明材质 | 导入并警告或正常显示 |
| 带内嵌纹理 | 导入 |
| 不支持纹理格式 | 几何兼容性单独报告 |
| 带动画 | 导入并统计动画 |
| 带 Skin | 导入并统计 joints |
| 带 Morph | 导入并统计 targets |
| 多 Mesh | 导入并统计 |
| 空场景 | 拒绝或明确 DisplayOnly |
| 损坏 GLB | 精确拒绝 |
| 不支持 required extension | 拒绝并列出名称 |
| 极小模型 | 自动适配 |
| 极大模型 | 自动适配 |
| 原点偏移 | 自动居中 |
| 重复模型 | 检测并复用缓存 |

如果实际缺少某类模型：

使用生成 fixture 覆盖结构检查。

不得声称已经验证真实材质渲染，除非真机或模拟器真实加载并截图。

────────────────────────────────
二十七、自动运行策略
────────────────────────────────

用户休息期间，尽量自动推进。

执行顺序：

1. 静态源码分析；
2. 单元测试；
3. host-side GLB 测试；
4. entry@default 增量构建；
5. 生成 Debug HAP；
6. 检查已连接设备；
7. 有真机则优先真机；
8. 真机断开则检查模拟器；
9. 有模拟器则启动模拟器；
10. 安装 HAP；
11. 启动应用；
12. 自动进入模型导入页面；
13. 使用 Debug-only 自动导入入口；
14. 导入 Grace；
15. 读取日志；
16. 检查模型记录；
17. 检查缓存；
18. 重复导入；
19. 导入损坏文件；
20. 导入不支持扩展 fixture；
21. 检查用户提示；
22. 截图；
23. 清理 Debug-only 自动入口；
24. 再次构建；
25. 再次安装；
26. 最终 smoke test；
27. 更新 TODO.md。

如果设备断开：

最多进行一次合理重连。

不要无限循环。

真机不可用后：

优先切换模拟器。

模拟器不可用后：

继续完成所有 host 和单元测试。

只有设备层确实无法执行的项目，明确标注“设备验证受环境限制”。

不得把整项任务标记为完全真机通过。

────────────────────────────────
二十八、Debug-only 自动导入入口
────────────────────────────────

为了无人值守测试，允许增加 Debug-only 自动测试入口。

要求：

- 仅 Debug 构建可用；
- 不显示在 Release UI；
- 可从 test_models 或临时推送目录导入；
- 可传入文件路径或沙箱路径；
- 自动执行完整导入；
- 自动输出阶段日志；
- 自动报告 ModelImportResult；
- 自动验证模型记录；
- 自动打开 PoC 或模型预览；
- 自动截图，如工具允许。

不得将 Windows 路径写进正式业务代码。

允许通过：

- 编译宏；
- Debug 参数；
- 测试配置；
- hdc push；
- 测试专用 ViewModel 方法。

验收完成后删除：

- 自动触发；
- 测试按钮；
- 固定模型名；
- rawfile 测试模型；
- 测试 UI。

可以保留：

- 正式通用 importModelFromSandboxPath 方法；
- 单元测试；
- ohosTest；
- host 工具。

但如果通用方法无实际调用者且仅为测试引入，按最小代码原则删除。

────────────────────────────────
二十九、日志规范
────────────────────────────────

允许日志：

- import start；
- stage changed；
- source hash 前 8 位；
- file size；
- compatibility；
- extension summary；
- cache hit / miss；
- conversion start / done；
- validation result；
- ArkGraphics load result；
- bounds summary；
- import completed；
- errorCode。

禁止日志：

- 完整绝对路径；
- 完整模型 JSON；
- 用户聊天；
- 完整 hash；
- 二进制内容；
- 每个 accessor 全量输出；
- 每帧 Scene 信息；
- API Key。

错误日志应包含：

stage
errorCode
safe diagnostic

检查：

- FATAL；
- SIGSEGV；
- abort；
- TypeError；
- Resource；
- ArkGraphics parse；
- expected JSON chunk；
- out of range；
- NaN；
- Infinity；
- memory；
- fd leak；
- Scene disposed。

────────────────────────────────
三十、资源和内存
────────────────────────────────

大模型导入必须避免：

- 多份完整文件同时复制；
- JSON 字符串长期保留；
- BIN 多次复制；
- meshopt 输出重复分配；
- 临时文件不清理；
- fd 不关闭；
- NAPI buffer 不释放；
- Scene 泄漏。

检查：

- 文件句柄 finally 关闭；
- NAPI allocated memory 生命周期；
- Uint8Array 是否复制；
- 转换后原 buffer 是否释放；
- 失败路径是否清理；
- 页面离开是否释放 Scene；
- 重复导入是否复用缓存。

如果文件超过合理上限：

例如 500 MB，具体按项目能力确认。

导入前提示或拒绝。

不得尝试无上限读取超大文件到内存。

────────────────────────────────
三十一、UI 最小改动
────────────────────────────────

本任务只允许必要 UI：

1. 导入进度；
2. 兼容性摘要；
3. 错误详情；
4. 复制诊断信息；
5. 模型详情统计。

不要重新设计整个动作管理页面。

不要开始完整模型库 UI。

模型导入完成后至少能显示：

- 文件名；
- 文件大小；
- Mesh；
- Material；
- Animation；
- Joint；
- Morph；
- Compatibility；
- Warnings。

如果空间不足：

使用模型详情弹层。

────────────────────────────────
三十二、构建与安装规则
────────────────────────────────

执行：

1. 相关单元测试；
2. entry@default 增量构建；
3. entry@ohosTest 构建，如现有测试使用；
4. Debug HAP 构建；
5. 检查 HAP 路径；
6. 覆盖安装；
7. 保留用户数据；
8. 启动应用；
9. 验证导入；
10. 检查 hilog。

默认禁止 clean。

只有以下情况允许 clean：

- 修改 CMake；
- 修改 Native 模块配置；
- 删除 Native 源文件导致缓存异常；
- 连续两次明确增量构建缓存错误。

同一失败命令不要无意义重复超过两次。

每次重试前必须有新修复或新证据。

────────────────────────────────
三十三、模拟器策略
────────────────────────────────

真机断开时允许使用模拟器。

执行：

1. 检查 DevEco Device Manager；
2. 检查已有 HarmonyOS 模拟器；
3. 启动一个兼容当前 API 的模拟器；
4. 等待 boot completed；
5. 使用 hdc devices 确认；
6. 安装 HAP；
7. 启动 ArkTavern；
8. 自动进入模型导入测试；
9. 收集 hilog；
10. 截图。

注意：

模拟器可能不完全代表真机 GPU 或 ArkGraphics 行为。

因此报告必须区分：

- host 测试；
- 模拟器测试；
- 真机测试。

不得把模拟器通过写成真机通过。

如果模拟器 ArkGraphics 不可用：

仍完成容器、转换、缓存和数据层测试。

────────────────────────────────
三十四、Grace 模型专项验收
────────────────────────────────

使用：

Grace Ashcroft - Lying Pose Mobile.glb

完成：

1. 读取原文件；
2. SHA-256；
3. GLB 容器校验；
4. JSON 解析；
5. 扩展扫描；
6. meshopt 检测；
7. quantization 检测；
8. meshopt 转换；
9. 输出 GLB 再验证；
10. ArkGraphics 加载；
11. Scene 创建；
12. Bounds；
13. baseFitScale；
14. 模型列表记录；
15. PoC 显示；
16. 重复导入；
17. 缓存命中；
18. 删除测试导入记录后重新导入；
19. 检查缓存复用；
20. 日志无 expected JSON chunk。

记录：

- 原文件大小；
- 转换后大小；
- mesh 数；
- primitive 数；
- material 数；
- animation 数；
- skin 数；
- joint 数；
- morph 数；
- extensions；
- conversion time；
- load time；
- bounds；
- baseFitScale；
- compatibility；
- warnings。

────────────────────────────────
三十五、负向测试
────────────────────────────────

至少自动测试：

1. 8 字节全零；
2. 12 字节错误 magic；
3. version = 1；
4. declared total length = 0xFFFFFFFF；
5. JSON chunkLength = 0xFFFFFFFF；
6. JSON chunk 非 4 对齐；
7. JSON chunk 越界；
8. chunk 0 为 BIN；
9. 非法 JSON；
10. asset.version = 1.0；
11. bufferView 越界；
12. accessor 越界；
13. unsupported required extension；
14. meshopt 参数越界；
15. 空 scene；
16. 无 POSITION；
17. NaN Bounds fixture，如可构造；
18. 极端尺寸。

每个测试必须：

- 被拒绝或降级；
- 返回预期 errorCode；
- 不 crash；
- 不留下模型记录；
- 不留下临时文件；
- 不污染缓存；
- 不产生 FATAL。

────────────────────────────────
三十六、并发与重复点击
────────────────────────────────

测试用户快速点击两次导入。

要求：

- 同一 ViewModel 同时只允许一个导入任务；
- 第二次提示正在导入；
- 或排队，但不能并发写同一缓存；
- 同一 source hash 只允许一个转换；
- 不产生临时文件冲突；
- 不产生两个模型记录；
- 取消后可重新导入。

缓存写入使用：

临时文件
→ fsync，如适用
→ 原子 rename

避免读取半写文件。

────────────────────────────────
三十七、安全
────────────────────────────────

所有外部模型都视为不可信输入。

必须防护：

- 整数溢出；
- 数组越界；
- 路径穿越；
- 超大长度；
- JSON 深度；
- 巨量数组；
- 巨量 accessor count；
- 巨量图片；
- NAPI 内存分配；
- 不受控日志；
- 恶意 URI；
- data URI 超大；
- 外部路径逃逸沙箱。

不得直接使用模型 JSON 中的文件名拼接沙箱路径。

必须清洗 basename。

不得执行模型中的任何脚本或 URI。

────────────────────────────────
三十八、TODO.md 完成条件
────────────────────────────────

只有满足以下条件才标记完成：

1. GLB Validator 单元测试通过；
2. Gltf Semantic Validator 通过；
3. Grace 正向导入通过，至少 host + 设备之一；
4. meshopt 转换后 GLB 验证通过；
5. 重复导入检测通过；
6. 缓存命中测试通过；
7. 至少 10 个负向 fixture 通过；
8. 自动取景计算通过；
9. 无 expected JSON chunk；
10. 无 FATAL；
11. Debug 自动入口已清理；
12. entry@default 构建成功。

如果设备和模拟器都不可用：

可以将代码与 host 测试完成记录为：

实现完成，设备验收待补。

不得写“全部完成”。

────────────────────────────────
三十九、TODO.md 记录格式
────────────────────────────────

在 TODO.md 末尾追加：

## T-3D.6D 模型导入稳定性、兼容性诊断与自动验收

### 任务目标

记录：

- 导入前结构扫描；
- 严格校验；
- 扩展兼容；
- 缓存；
- 去重；
- 自动取景；
- 精确错误；
- 自动测试。

### 原始调用链

记录真实文件和方法。

### GLB 修复

记录：

- chunkLength 规则；
- Reader 行为；
- Writer 行为；
- padding；
- overflow 检查。

### glTF 语义验证

记录覆盖内容。

### 扩展兼容

记录：

- 直接支持；
- 可转换；
- 保留；
- 不支持。

### meshopt

记录：

- 解码；
- JSON 更新；
- BIN 重建；
- 输出验证；
- Grace 结果。

### 缓存与去重

记录：

- SHA-256；
- cache key；
- 命中；
- 失效；
- 重复导入。

### 自动取景

记录：

- bounds；
- center；
- radius；
- baseFitScale；
- 极端尺寸；
- 原点偏移。

### 测试矩阵

记录每一类测试结果。

### 设备结果

分别记录：

- host；
- 模拟器；
- 真机。

### Debug 清理

记录删除内容。

### 修改文件

列出文件和职责。

### 已知限制

例如：

- 暂不支持外部资源 glTF；
- 暂不支持 Draco；
- 部分纹理格式；
- 设备验收受限；
- 动画播放尚未实现。

### 最终结论

只有真实满足完成条件时写：

完成。

否则写：

实现完成，设备验收待补。

────────────────────────────────
四十、最终报告
────────────────────────────────

最终只报告：

1. 原始导入调用链；
2. 根因清单；
3. 修改文件；
4. 新增类型；
5. GLB Validator；
6. glTF Semantic Validator；
7. chunkLength 最终实现；
8. meshopt 转换结果；
9. KHR_mesh_quantization 决策；
10. 扩展兼容矩阵；
11. Grace 原文件信息；
12. Grace 转换结果；
13. ArkGraphics 加载结果；
14. Bounds；
15. baseFitScale；
16. 自动取景；
17. 缓存 key；
18. 缓存命中；
19. 重复导入；
20. 负向测试；
21. 取消测试；
22. 并发测试；
23. entry@default；
24. entry@ohosTest；
25. HAP 路径；
26. 真机结果；
27. 模拟器结果；
28. hilog；
29. 截图；
30. Debug 清理；
31. TODO.md 行号；
32. 已知限制；
33. 下一步建议。

完成后停止。

不得开始：

- 完整独立模型查看器；
- 动画时间轴；
- 骨骼编辑；
- 材质编辑；
- 灯光编辑；
- 模型截图；
- 动作重定向；
- 聊天动作联动；
- 其他无关任务。