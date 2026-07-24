# T-3D.6E 模型不可见诊断、兼容性分层与手动人形骨骼映射

继续开发 HarmonyOS NEXT 原生项目 ArkTavern。

项目路径：

D:\DevEco_studio\ArkTavern

当前环境：

- 用户已经连接模拟器；
- 当前可以在模拟器中进入应用；
- 当前模型能够完成导入流程；
- 但部分模型导入后画面中什么也看不到；
- 同一模型在其他 GLB 查看器中可以正常显示；
- 很多模型在 Blender 中能够看到骨架；
- ArkTavern 经常将这些模型显示为“当前模型不兼容”；
- 当前已有：
  - GLB 容器验证；
  - glTF 语义验证；
  - meshopt 转换；
  - KHR_mesh_quantization 保留；
  - 模型信息扫描；
  - Bounds 分析；
  - 自动取景；
  - PoC 与聊天页面统一手势；
  - 0.1～20 倍相对缩放；
  - Grace 模型 host-side 扫描；
  - 模拟 pointer 手势测试。

本任务优先级：

P0：查清并修复“模型导入成功但不可见”。

P1：查清“当前模型不兼容”的真实判断条件，拆分兼容状态。

P2：加入自动人形骨骼映射诊断。

P3：实现可保存的手动人形骨骼映射基础功能。

P4：为后续动作重定向建立数据结构和校验，但本轮不实现完整动作重定向播放器。

必须按顺序执行。

如果 P0 尚未解决，不得跳过直接做手动骨骼映射。

完成本任务后停止，不进入完整模型查看器、动画时间轴、材质编辑或灯光编辑。

────────────────────────────────
一、无人值守执行规则
────────────────────────────────

用户暂时不参与即时确认。

遇到普通问题时：

- 自行分析；
- 自行查源码；
- 自行修改；
- 自行构建；
- 自行安装；
- 自行运行模拟器；
- 自行收集 hilog；
- 自行截图；
- 自行生成测试数据；
- 自行修复编译错误。

不得因为以下问题立即停止：

- 一个编译错误；
- 一个 API 不熟悉；
- 一个页面控件找不到；
- 自动化点击失败；
- 模型路径不同；
- 单个测试模型加载失败；
- 一次模拟器连接波动；
- 日志中出现普通 warning。

模拟器短暂断开：

最多重连一次。

重连失败：

继续 host 测试、单元测试和静态验证。

只有以下情况允许停止：

1. Git 冲突无法安全处理；
2. 必须覆盖用户未提交的重要代码；
3. 需要外部账号、密码、证书；
4. 必须获得用户手中尚未提供的关键模型才能继续；
5. DevEco、模拟器、host 测试全部不可用；
6. 连续两次证明是环境故障而非代码问题。

不得：

- git reset；
- git stash；
- 覆盖用户修改；
- 删除用户模型；
- 删除现有有效缓存；
- 修改聊天数据库；
- 修改聊天导入导出；
- 修改角色卡格式；
- 修改已完成的 meshopt chunkLength 规则；
- 无依据降低当前 20 倍缩放范围。

────────────────────────────────
二、开始前检查
────────────────────────────────

依次执行：

1. 阅读 AGENTS.md；
2. 阅读 project_memory.md；
3. 阅读 TODO.md 中：
   - T-3D.5D；
   - T-3D.6C；
   - T-3D.6C-C3；
   - T-3D.6D；
4. 执行 git status；
5. 记录当前所有未提交修改；
6. 确认 HAP 路径；
7. 执行 hdc list targets；
8. 确认当前模拟器 target；
9. 启动 ArkTavern；
10. 复现一次：
    - 模型导入成功；
    - PoC 页面无模型；
11. 保存：
    - hilog；
    - 页面截图；
    - 当前模型信息；
    - 模型记录；
    - 模型缓存路径；
12. 找出以下真实调用链：
    - 文件导入；
    - 模型兼容性判定；
    - ArkGraphics Scene 创建；
    - 模型节点挂载；
    - Bounds 计算；
    - baseFitScale 计算；
    - 相机定位；
    - 模型 transform；
    - 骨架扫描；
    - 人形兼容判断；
    - 动作匹配判断。

重点检查文件：

- Character3DPocPage.ets
- Character3DPocViewModel.ets
- Character3DPanel.ets
- Character3DPanelViewModel.ets
- Character3DGestureHandler.ets
- Character3DDisplayConfig.ets
- Character3DModelCompatibilityService.ets
- Character3DModelService.ets
- Character3DService.ets
- MeshoptGlbDecoder.cpp
- ModelInspector.ets
- ModelImportDiagnostics.ets
- ModelImportResult.ets
- 与 ArkGraphics Scene、Camera、Node 相关文件
- 与骨骼名称识别、人形兼容相关文件
- 与模型数据库记录相关文件
- 与模型详情 UI 相关文件。

以项目实际文件名为准。

────────────────────────────────
三、先复现并分类“导入后不可见”
────────────────────────────────

不得只凭肉眼说“没看到”。

每次模型导入后，必须记录：

- import success；
- source path 的安全 basename；
- sourceSha256 前 8 位；
- converted；
- converted file size；
- ArkGraphics load success；
- sceneCount；
- selectedSceneIndex；
- rootNodeCount；
- totalNodeCount；
- meshCount；
- primitiveCount；
- renderablePrimitiveCount；
- materialCount；
- skinCount；
- jointCount；
- animationCount；
- morphTargetCount；
- bounds min；
- bounds max；
- bounds center；
- bounds size；
- bounds radius；
- baseFitScale；
- zoomFactor；
- finalScale；
- root offset；
- root rotation；
- camera position；
- camera target；
- camera distance；
- nearPlane；
- farPlane；
- viewportWidth；
- viewportHeight；
- scene attached；
- model root attached；
- visible mesh node count；
- hidden mesh node count。

建立不可见原因枚举：

enum ModelVisibilityIssue {
  None,
  SceneNotSelected,
  SceneRootNotAttached,
  ModelRootNotAttached,
  NoRenderableMesh,
  MeshNodesHidden,
  InvalidNodeTransform,
  InvalidWorldMatrix,
  InvalidBounds,
  ZeroBounds,
  BoundsCalculatedInWrongSpace,
  OriginFarFromGeometry,
  ModelTooSmall,
  ModelTooLarge,
  CameraNotFacingModel,
  CameraInsideModel,
  NearPlaneClipping,
  FarPlaneClipping,
  ScaleAppliedTwice,
  ScaleNotApplied,
  OffsetAppliedTwice,
  MaterialFullyTransparent,
  BackFaceCulled,
  NegativeScaleWinding,
  UnsupportedMaterial,
  InvalidSkinMatrices,
  InvalidJointWeights,
  AnimationMovedModelAway,
  QuantizedPositionUnsupported,
  ArkGraphicsNodeNotRendered,
  Unknown
}

导入完成后，运行：

analyzeModelVisibility()

返回：

interface ModelVisibilityReport {
  visible: boolean;
  primaryIssue: ModelVisibilityIssue;
  secondaryIssues: ModelVisibilityIssue[];
  renderableMeshCount: number;
  visibleMeshCount: number;
  boundsValid: boolean;
  boundsCenter: Vec3;
  boundsRadius: number;
  cameraDistance: number;
  suggestedAction: string;
  warnings: string[];
}

不允许继续只输出：

模型不可见。

必须输出具体原因。

────────────────────────────────
四、检查 Scene 选择和节点挂载
────────────────────────────────

重点检查 glTF 的默认场景规则。

glTF JSON 可能：

- 包含 scenes；
- 没有 scene 字段；
- scene 字段指向 0；
- scene 字段指向其他 scene；
- 一个模型有多个 scene。

正确策略：

1. 如果 glTF.scene 存在且合法：
   使用指定 scene；
2. 如果 glTF.scene 不存在但 scenes 非空：
   默认使用 scenes[0]；
3. 如果 scenes 为空但 nodes 存在：
   根据未被其他节点引用的根节点构建临时根；
4. 不得因为 scene 字段缺失就得到空 Scene；
5. 不得只挂载第一个 node；
6. 必须挂载当前 scene.nodes 中全部根节点；
7. 必须递归处理 children；
8. 防止循环引用；
9. 防止重复挂载；
10. 保证 modelRoot 实际加入 ArkGraphics Scene。

增加检查：

- Scene 是否创建；
- ModelRoot 是否创建；
- ModelRoot 是否加入 Scene；
- SceneRoot 下是否真实存在渲染节点；
- 页面显示的 Scene 是否是导入后的 Scene；
- 是否创建了新 Scene 但 Component3D 仍持有旧 Scene；
- 是否 ViewModel 已更新但 ArkUI 没有刷新 Component3D；
- 是否页面返回后 Scene 被 dispose。

如果发现模型加载成功但挂错 Scene：

修复生命周期和绑定。

────────────────────────────────
五、检查 Node TRS 和 matrix
────────────────────────────────

glTF node 可以使用：

- matrix；
- translation；
- rotation；
- scale。

规则：

- matrix 与 TRS 不应同时使用；
- 如果 matrix 存在，应优先按 matrix；
- rotation 是 quaternion：
  [x, y, z, w]；
- scale 可能包含负值；
- translation 可能很大。

必须检查当前实现是否：

- 把 quaternion 顺序写成 [w, x, y, z]；
- 忽略 node.matrix；
- matrix 行列主序错误；
- 父子矩阵乘法顺序错误；
- world = local × parent 写反；
- scale 应用两次；
- model root transform 与 node transform 重复；
- 负 scale 导致 winding 反转；
- NaN matrix 继续传入 ArkGraphics。

增加矩阵测试：

- 纯 translation；
- 纯 rotation；
- 纯 scale；
- matrix node；
- 父子嵌套；
- 负 scale；
- 非均匀 scale；
- 多层父节点；
- 原点偏移模型。

所有最终矩阵必须验证：

Number.isFinite。

发现非法矩阵时：

- 标记具体 node；
- 不 crash；
- 不污染整个 Scene；
- 允许跳过单个非法节点并警告。

────────────────────────────────
六、修复 Bounds 计算
────────────────────────────────

当前自动取景可能依赖 accessor.min/max。

必须检查以下风险：

1. accessor 没有 min/max；
2. min/max 是局部坐标；
3. 没有应用 node world transform；
4. SkinnedMesh Bounds 不等于静态 Mesh Bounds；
5. meshopt 转换后 accessor min/max 缺失；
6. quantized POSITION 需要按 componentType 解释；
7. 一个模型有多个 mesh；
8. 一个 mesh 被多个 node 实例化；
9. morph target 改变 Bounds；
10. 动画 frame 0 改变节点位置。

建立分层 Bounds 策略：

### 第一优先级

读取 POSITION accessor.min/max。

将 8 个包围盒角点通过 node world matrix 变换到世界坐标。

合并所有实例化 mesh 的世界 Bounds。

### 第二优先级

如果 POSITION accessor 没有 min/max：

读取 POSITION accessor 数据并计算。

必须支持：

- FLOAT；
- BYTE；
- UNSIGNED_BYTE；
- SHORT；
- UNSIGNED_SHORT；
- normalized；
- KHR_mesh_quantization。

不得把量化整数直接当最终世界坐标。

### SkinnedMesh

初始取景可以使用：

- bind pose；
- rest pose；
- node world transform 后的静态几何 Bounds。

如果当前 ArkGraphics 可以读取变形后 Bounds：

优先使用引擎 Bounds。

如果不能：

至少使用 bind pose Bounds。

### 最终检查

bounds 必须满足：

- min/max 有限；
- min <= max；
- radius > epsilon；
- 不为 NaN；
- 不为 Infinity。

如果 Bounds 无效：

不得继续使用：

baseFitScale = Infinity
或
baseFitScale = 0。

回退：

- 使用几何位置扫描；
- 或使用默认安全范围；
- 并报告原因。

────────────────────────────────
七、自动取景修复
────────────────────────────────

统一自动取景：

modelCenter =
(boundsMin + boundsMax) / 2

modelSize =
boundsMax - boundsMin

modelRadius =
length(modelSize) / 2

viewer root 应将几何中心移动到查看中心：

viewerRootOffset =
-modelCenter

不要直接改写模型文件中的 node transform。

计算：

baseFitScale

必须考虑：

- viewport width；
- viewport height；
- FOV；
- aspect ratio；
- modelRadius；
- 模型横向和纵向尺寸；
- 当前投影类型。

禁止只按模型高度计算而忽略宽度。

如果模型是横躺的 Grace：

也必须完整进入画面。

加入统一方法：

frameModel()

执行：

1. 清理当前手势状态；
2. zoomFactor = 1.0；
3. offsetX = 0；
4. offsetY = 0；
5. 使用真实 Bounds；
6. 更新 viewer root center offset；
7. 更新 baseFitScale；
8. 更新 camera target；
9. 更新 camera distance；
10. 更新 near/far；
11. 请求渲染。

PoC 页面增加正式按钮：

定位模型

或：

适配视图

此按钮不是 Debug 按钮，可以保留。

作用：

重新计算 Bounds 并自动取景。

────────────────────────────────
八、相机与裁剪检查
────────────────────────────────

模型不可见时检查：

- camera 是否存在；
- camera 是否为当前 Scene camera；
- camera target 是否指向模型中心；
- camera up vector 是否有效；
- cameraDistance 是否为有限数；
- nearPlane 是否大于 0；
- farPlane 是否大于 nearPlane；
- 模型是否位于相机后方；
- 相机是否进入模型；
- 模型是否被 near plane 切掉。

根据 modelRadius 动态设置：

nearPlane =
max(minNear, cameraDistance - modelRadius * safetyFactor)

farPlane =
cameraDistance + modelRadius * farSafetyFactor

但 nearPlane 必须保持正值。

不要照搬固定数值。

要求：

- 极小模型可显示；
- 极大模型可显示；
- 横躺模型可显示；
- 原点偏移模型可显示；
- 20 倍缩放不会立刻被 near plane 切掉；
- 缩小到 0.1 倍不会超过 far plane。

如果当前 ArkGraphics camera API 不支持动态 near/far：

记录限制，并使用可用 API 的最安全方案。

────────────────────────────────
九、材质导致不可见的排查
────────────────────────────────

模型几何存在但不可见时检查：

- alphaMode；
- baseColorFactor alpha；
- baseColorTexture alpha；
- material opacity；
- doubleSided；
- back-face culling；
- negative determinant；
- winding；
- unsupported shader；
- missing texture；
- fully transparent material。

增加诊断模式：

enum ModelDiagnosticRenderMode {
  Normal,
  ForceUnlit,
  ForceOpaque,
  DisableBackFaceCulling,
  WireframeOrDebugMaterial
}

如果 ArkGraphics 支持相应能力，PoC 诊断菜单可临时提供：

- 正常材质；
- 强制无光照；
- 强制不透明；
- 双面显示。

正式模型默认仍使用原材质。

如果“强制无光照”后可见：

说明材质或光照存在问题。

如果“双面显示”后可见：

说明 winding、negative scale 或 culling 存在问题。

不得永久修改用户模型材质来掩盖问题。

────────────────────────────────
十、Skin 和骨骼导致不可见的排查
────────────────────────────────

Blender 中有骨架，但导入后不可见，需要检查：

- skin.joints；
- inverseBindMatrices；
- JOINTS_0；
- WEIGHTS_0；
- JOINTS_1；
- WEIGHTS_1；
- 权重归一化；
- joint 索引范围；
- inverse bind matrix 数量；
- skin.skeleton；
- joint world matrix；
- mesh bind transform；
- IBM 乘法顺序。

建立 SkinValidationReport：

interface SkinValidationReport {
  skinCount: number;
  validSkinCount: number;
  jointCount: number;
  inverseBindMatrixCount: number;
  meshWithSkinCount: number;
  meshesMissingWeights: number;
  meshesMissingJoints: number;
  invalidJointIndexCount: number;
  invalidWeightCount: number;
  zeroWeightVertexCount: number;
  nonNormalizedWeightVertexCount: number;
  warnings: string[];
}

重点检查：

- joints 数量与 inverseBindMatrices count 是否一致；
- JOINTS accessor componentType；
- WEIGHTS accessor componentType；
- normalized 是否处理；
- 权重全 0 时的回退；
- joint index 是否超过当前 skin.joints 长度；
- skin.skeleton 缺失时是否错误判定不兼容。

skin.skeleton 在 glTF 中是可选字段。

如果缺失：

不得判定 Skin 不兼容。

可以从 joints 的共同祖先或层级关系推导 skeleton root。

────────────────────────────────
十一、动画导致模型跑出视野
────────────────────────────────

导入模型时默认不要自动应用未知动画到任意时间点。

检查：

- Scene 创建后是否自动播放第一个 animation；
- 当前时间是否不是 0；
- 动画 translation 是否将 root 移走；
- animation scale 是否为 0；
- animation 数据异常；
- 动画循环是否在模型加载前启动。

诊断步骤：

1. 禁用所有 animation；
2. 使用 bind/rest pose；
3. 自动取景；
4. 确认模型是否可见；
5. 再单独启用 animation。

如果禁用动画后模型可见：

问题归类为：

AnimationMovedModelAway
或
InvalidAnimationTransform。

导入阶段默认显示：

rest pose 或 bind pose。

不要因为动画异常导致整个模型显示为空白。

────────────────────────────────
十二、彻底拆分“兼容”的含义
────────────────────────────────

不得继续只用一个：

compatible: boolean

表示模型状态。

建立：

interface ModelCapabilityReport {
  containerValid: CapabilityState;
  semanticValid: CapabilityState;
  sceneLoadable: CapabilityState;
  geometryRenderable: CapabilityState;
  materialRenderable: CapabilityState;
  textureRenderable: CapabilityState;
  skeletonPresent: CapabilityState;
  skinValid: CapabilityState;
  animationPresent: CapabilityState;
  animationPlayable: CapabilityState;
  humanoidAutoMapping: HumanoidMappingState;
  humanoidManualMapping: HumanoidMappingState;
  motionRetargeting: CapabilityState;
  warnings: ModelCapabilityWarning[];
}

CapabilityState：

- Supported；
- PartiallySupported；
- Unsupported；
- NotPresent；
- Unknown。

HumanoidMappingState：

- NotEvaluated；
- NoSkeleton；
- AutoMapped；
- PartiallyMapped；
- NeedsManualMapping；
- ManualMapped；
- InvalidMapping。

页面必须分别显示：

- 模型显示；
- 材质；
- 纹理；
- 骨架；
- 动画；
- 人形骨骼映射；
- 动作匹配。

禁止：

模型可以显示，但自动人形识别失败
→ 显示“当前模型不兼容”。

正确显示示例：

模型显示：可用  
骨架：已检测到 68 个关节  
人形映射：需要手动匹配  
动作匹配：尚未配置

无 Skin 的静态模型：

模型显示：可用  
骨架：未检测到  
动作匹配：不支持骨骼动作

Skin 存在但自动识别失败：

模型显示：可用  
骨架：已检测到  
人形映射：自动匹配失败，可手动配置

只有 GLB、Scene 或 Geometry 确实不能加载时，才显示：

模型不可用。

────────────────────────────────
十三、查清当前“不兼容”判定
────────────────────────────────

搜索所有：

- compatible；
- incompatible；
- isHumanoid；
- humanoid；
- skeleton；
- bone；
- joint；
- action compatible；
- 部分人形；
- 当前模型不兼容；
- 骨骼未知。

找到最终显示“当前模型不兼容”的准确条件。

记录：

- 哪个文件；
- 哪个方法；
- 哪个字段；
- 哪些骨骼名称必须存在；
- 是否大小写敏感；
- 是否要求固定层级；
- 是否只支持 Mixamo；
- 是否只支持某个测试模型；
- 是否将 skin.skeleton 缺失当错误；
- 是否将 animationCount = 0 当错误；
- 是否将骨骼名称不匹配当整体模型错误。

修复原则：

自动映射失败只能影响：

humanoidAutoMapping

不得影响：

sceneLoadable
geometryRenderable
skeletonPresent。

────────────────────────────────
十四、骨架存在性判断
────────────────────────────────

骨架存在判断应基于 glTF 数据，而不是只看名字。

优先判断：

skinCount > 0
且
至少一个 skin.joints 非空。

额外统计：

- 所有 skin.joints；
- 去重 joint node；
- joint hierarchy；
- inverseBindMatrices；
- skinned mesh；
- JOINTS/WEIGHTS attributes。

Blender 中看得到 Armature，但导出的 GLB 可能：

1. 没有导出 Skin；
2. Armature 存在但 Mesh 未绑定；
3. 只有 node hierarchy，没有 skin；
4. Apply Modifiers 或导出设置移除了骨骼；
5. 只导出当前可见对象；
6. Mesh 没有 Armature Modifier；
7. 没有勾选 Skinning。

如果 GLB 中：

skinCount = 0

明确显示：

GLB 中未检测到 Skin。Blender 文件可能有 Armature，但导出结果没有包含可用于蒙皮的骨骼数据。

不得说：

模型损坏。

────────────────────────────────
十五、统一人形关节定义
────────────────────────────────

建立统一标准：

enum HumanoidJoint {
  Root,
  Hips,

  Spine,
  Chest,
  UpperChest,

  Neck,
  Head,

  LeftEye,
  RightEye,
  Jaw,

  LeftShoulder,
  LeftUpperArm,
  LeftLowerArm,
  LeftHand,

  RightShoulder,
  RightUpperArm,
  RightLowerArm,
  RightHand,

  LeftUpperLeg,
  LeftLowerLeg,
  LeftFoot,
  LeftToes,

  RightUpperLeg,
  RightLowerLeg,
  RightFoot,
  RightToes
}

分为：

### 必需关节

- Hips；
- Spine 或 Chest 至少一个；
- Head；
- LeftUpperArm；
- LeftLowerArm；
- LeftHand；
- RightUpperArm；
- RightLowerArm；
- RightHand；
- LeftUpperLeg；
- LeftLowerLeg；
- LeftFoot；
- RightUpperLeg；
- RightLowerLeg；
- RightFoot。

### 推荐关节

- Root；
- Chest；
- Neck；
- Shoulder；
- Toes。

### 可选关节

- UpperChest；
- Eye；
- Jaw；
- 手指；
- 额外脊柱。

动作重定向资格不得要求所有可选关节都存在。

────────────────────────────────
十六、自动骨骼名称匹配
────────────────────────────────

自动匹配不得只支持一套固定名称。

对骨骼名称标准化：

1. 转小写；
2. 删除空格；
3. 删除下划线；
4. 删除连字符；
5. 删除点；
6. 删除 namespace；
7. 删除常见前缀：
   - mixamorig；
   - armature；
   - rig；
   - skeleton；
   - bip；
   - bone；
8. 保留原始名称用于 UI。

支持常见同义词。

例如：

Hips：

- hips；
- pelvis；
- hip；
- rootpelvis；
- bip01pelvis；
- j_bip_c_hips。

Spine：

- spine；
- spine01；
- abdomen；
- waist。

Chest：

- chest；
- spine02；
- spine2；
- torso；
- upperbody。

Head：

- head；
- headjoint；
- j_bip_c_head。

LeftUpperArm：

- leftarm；
- lupperarm；
- upperarml；
- arm_l；
- l_arm；
- leftuparm。

RightUpperArm 同理。

LeftUpperLeg：

- leftupleg；
- leftthigh；
- thigh_l；
- upperleg_l。

Foot：

- foot；
- ankle。

Toes：

- toe；
- toebase；
- ball。

但自动匹配不能只依赖名称。

综合评分：

autoMappingScore =
nameScore
+ hierarchyScore
+ sideScore
+ spatialScore
+ lengthScore
+ parentChildScore

输出：

interface HumanoidJointCandidate {
  sourceNodeIndex: number;
  sourceBoneName: string;
  score: number;
  nameScore: number;
  hierarchyScore: number;
  sideScore: number;
  spatialScore: number;
  reasons: string[];
}

每个目标关节保留前 5 个候选。

置信度：

- >= 0.85：自动接受；
- 0.65～0.85：建议但需要确认；
- < 0.65：不自动映射。

具体阈值可根据项目评分范围调整。

不得低置信度强行匹配。

────────────────────────────────
十七、层级和空间辅助判断
────────────────────────────────

骨骼层级关系应符合人体大体结构：

Hips
→ Spine
→ Chest
→ Neck
→ Head

Chest
→ Shoulder
→ UpperArm
→ LowerArm
→ Hand

Hips
→ UpperLeg
→ LowerLeg
→ Foot
→ Toes

不得要求骨骼直接相邻。

允许中间存在：

- twist；
- helper；
- roll；
- deform；
- end；
- offset；
- correction；
- extra spine。

自动匹配时可以跳过辅助骨。

左右判断优先顺序：

1. 名称明确包含 left/right、l/r；
2. 父子结构；
3. 与身体中心的相对位置；
4. 其他对称骨骼。

不得只依赖 X 正负。

部分模型：

- 左右轴可能相反；
- 模型可能整体旋转；
- 可能使用 Z-up 导出；
- bind pose 可能不是 T-pose。

空间判断必须在统一的模型世界坐标或校准坐标中进行。

────────────────────────────────
十八、手动人形骨骼映射页面
────────────────────────────────

新增正式功能入口：

模型详情
→ 骨骼映射

或者动作管理页模型卡片：

配置骨骼

该页面不是 Debug 页面，可以保留。

页面建议包含：

### 顶部

- 模型名称；
- 骨骼数量；
- Skin 数量；
- 自动映射状态；
- 已匹配数量；
- 必需关节缺失数量；
- 保存；
- 重置；
- 自动匹配；
- 验证。

### 左侧或可滚动列表

显示标准人形关节：

- 髋部；
- 脊柱；
- 胸部；
- 颈部；
- 头部；
- 左肩；
- 左上臂；
- 左前臂；
- 左手；
- 右肩；
- 右上臂；
- 右前臂；
- 右手；
- 左大腿；
- 左小腿；
- 左脚；
- 右大腿；
- 右小腿；
- 右脚；
- 可选脚趾等。

每个关节显示：

- 未匹配；
- 自动匹配；
- 手动匹配；
- 低置信度；
- 冲突；
- 无效。

### 模型区域

显示：

- 3D 模型；
- 骨架线；
- 关节点；
- 当前选中骨骼高亮；
- 已匹配骨骼按状态高亮；
- 支持现有单指和双指操作；
- 支持定位模型；
- 支持只显示骨架；
- 支持显示/隐藏 Mesh。

### 骨骼树区域

显示模型真实 Node/Joint 层级：

- 搜索；
- 展开；
- 折叠；
- joint 名称；
- node index；
- parent；
- child 数；
- 是否属于 Skin；
- 是否有 inverse bind matrix；
- 是否已被映射。

────────────────────────────────
十九、手动映射交互
────────────────────────────────

第一阶段必须实现可靠的骨骼树选择。

流程：

1. 用户选择标准关节，例如“左上臂”；
2. 在模型骨骼树中选择对应 Bone；
3. 点击“匹配”；
4. 保存：
   LeftUpperArm → sourceNodeIndex；
5. 模型中高亮该 Bone；
6. 自动跳转下一个未匹配的必需关节。

支持：

- 取消匹配；
- 替换匹配；
- 查看候选；
- 使用自动建议；
- 搜索骨骼；
- 左右对称建议；
- 清空所有匹配。

默认禁止同一个 source bone 同时映射到两个必需关节。

如果用户明确替换：

先解除旧映射。

第二阶段可实现 3D 点选骨骼。

如果 ArkGraphics 当前不便做精确 Bone picking：

本任务至少完成：

- 骨骼树选择；
- 模型高亮联动。

不得为了 3D picking 阻塞整个任务。

────────────────────────────────
二十、骨架可视化
────────────────────────────────

建立 Bone Debug Overlay。

每个 joint 使用世界坐标。

父子 joint 之间画线。

要求：

- 不影响原模型材质；
- 可开关；
- 选中骨骼高亮；
- 自动映射骨骼与手动映射骨骼状态不同；
- 骨架线随模型旋转、缩放、平移；
- 不逐帧重建完整 Scene；
- 页面退出时释放资源。

如果 ArkGraphics 不支持直接绘制线：

可使用：

- 小型球体关节点；
- 细圆柱骨骼；
- 现有 debug primitive；
- Canvas 覆盖层投影。

选择项目中最稳定方案。

不得用文本字符模拟骨架。

────────────────────────────────
二十一、模型基础姿态和坐标校准
────────────────────────────────

用户需要能够手动定位模型的基本方向。

为每个模型保存：

interface ModelAlignmentConfig {
  rotationX: number;
  rotationY: number;
  rotationZ: number;
  centerOffsetX: number;
  centerOffsetY: number;
  centerOffsetZ: number;
  unitScale: number;
  groundOffset: number;
  forwardAxis: AxisDirection;
  upAxis: AxisDirection;
}

页面提供：

- 正视；
- 背视；
- 左视；
- 右视；
- 顶视；
- 底视；
- 旋转模型；
- 调整中心；
- 调整模型朝向；
- 设置脚底地面；
- 恢复自动校准。

这些是模型配置，不是普通相机视角。

必须区分：

### 相机视角

用户临时查看模型。

### 模型校准

用于骨骼空间判断和后续动作重定向。

保存模型校准时：

不得改写原 GLB。

保存 viewer root 或模型配置。

────────────────────────────────
二十二、Rest Pose 与 Bind Pose
────────────────────────────────

动作重定向前必须区分：

- Node rest pose；
- inverse bind pose；
- 当前 animation pose；
- 用户校准 pose。

建立：

interface SkeletonRestPose {
  nodeIndex: number;
  parentNodeIndex?: number;
  localTranslation: Vec3;
  localRotation: Quat;
  localScale: Vec3;
  worldMatrix: Mat4;
  inverseBindMatrix?: Mat4;
}

导入后提取 rest pose。

骨骼映射页面默认停在：

rest pose。

不要默认播放动画。

如果模型是 A-pose 或 T-pose：

记录姿态。

本任务不要求自动把 A-pose 修改成 T-pose，但要为后续保存：

- shoulder rest offset；
- arm rest rotation；
- leg rest rotation；
- forward axis；
- up axis。

────────────────────────────────
二十三、手动映射数据结构
────────────────────────────────

建议：

interface HumanoidBoneMapping {
  profileVersion: number;
  modelId: string;
  sourceSha256: string;
  skeletonHash: string;

  joints: Record<HumanoidJoint, HumanoidJointBinding>;

  alignment: ModelAlignmentConfig;

  restPoseCalibration?: RestPoseCalibration;

  autoMappedCount: number;
  manualMappedCount: number;
  requiredMissing: HumanoidJoint[];
  optionalMissing: HumanoidJoint[];

  valid: boolean;
  retargetReady: boolean;
  warnings: string[];

  createdAt: number;
  updatedAt: number;
}

interface HumanoidJointBinding {
  targetJoint: HumanoidJoint;
  sourceNodeIndex: number;
  sourceBoneName: string;
  mappingMethod: 'auto' | 'manual';
  confidence?: number;
  restLocalRotation?: Quat;
  restWorldPosition?: Vec3;
}

skeletonHash 至少由以下内容生成：

- joint node 数量；
- joint 名称；
- parent-child；
- skin.joints 顺序；
- inverse bind count。

如果模型文件变化导致 skeletonHash 改变：

旧映射不能直接静默使用。

显示：

模型骨架已变化，需要重新验证映射。

────────────────────────────────
二十四、手动映射验证
────────────────────────────────

点击“验证”后检查：

1. 所有必需关节是否存在；
2. sourceNodeIndex 是否合法；
3. 是否属于当前模型；
4. 同一 Bone 是否重复；
5. Head 是否位于 Spine/Chest 上方；
6. Hand 是否位于对应 Arm 链末端；
7. Foot 是否位于对应 Leg 链末端；
8. 左右关节是否反转；
9. UpperArm 是否是 LowerArm 的祖先；
10. LowerArm 是否是 Hand 的祖先；
11. UpperLeg 是否是 LowerLeg 的祖先；
12. LowerLeg 是否是 Foot 的祖先；
13. Head 是否与 Hips 位于同一主骨架树；
14. 必需链中是否跨越完全无关节点；
15. 关节世界坐标是否有限；
16. 骨骼长度是否接近 0；
17. 左右骨骼长度是否异常悬殊；
18. rest pose quaternion 是否有效；
19. 模型校准轴是否有效；
20. skeletonHash 是否一致。

返回：

interface HumanoidMappingValidationResult {
  valid: boolean;
  retargetReady: boolean;
  errors: HumanoidMappingIssue[];
  warnings: HumanoidMappingIssue[];
  missingRequired: HumanoidJoint[];
  missingOptional: HumanoidJoint[];
}

错误与警告分开。

例如：

- 缺少左手：错误；
- 缺少脚趾：警告；
- 没有 UpperChest：警告；
- 左右手可能反转：警告；
- 两个目标关节使用同一 Bone：错误。

只有验证通过才标记：

动作匹配：准备完成。

────────────────────────────────
二十五、兼容性 UI 文案
────────────────────────────────

修改模型卡片和详情页文案。

禁止继续使用模糊单值：

兼容
不兼容
部分人形

建议显示：

### 显示状态

- 可正常显示；
- 可显示，材质可能不完整；
- 已加载但当前未定位；
- 无可渲染几何；
- 系统 3D 引擎无法加载。

### 骨架状态

- 未检测到骨架；
- 检测到 1 个 Skin、68 个关节；
- 骨架数据异常；
- 骨架可用。

### 人形映射

- 已自动匹配；
- 自动匹配部分成功；
- 需要手动匹配；
- 已完成手动匹配；
- 映射无效。

### 动作状态

- 可用于人形动作；
- 需要完成骨骼映射；
- 当前只支持静态显示；
- 动画存在，但尚未实现动作重定向。

模型能显示但骨骼未映射时：

不得使用红色“模型不兼容”。

使用中性提示：

模型可显示，需要配置骨骼后才能匹配动作。

────────────────────────────────
二十六、动作匹配边界
────────────────────────────────

本任务只建立动作重定向的前置条件。

允许实现：

- mapping；
- validation；
- rest pose；
- alignment；
- skeleton hash；
- retargetReady；
- 一个简单的骨骼旋转预览测试。

本任务不实现：

- 完整动画时间轴；
- 多动画播放列表；
- 动画混合；
- IK；
- Foot IK；
- Root Motion 完整系统；
- 手指动作；
- 面部 Morph 动作；
- 动作编辑器；
- 动作导出；
- 实时动作捕捉。

如果已有一个简单测试动作：

可以在映射验证通过后执行：

- 左上臂抬起少量角度；
- 恢复 rest pose。

用于确认映射到了正确 Bone。

测试结束必须恢复模型姿态。

不得把简单测试写成完整动作兼容已完成。

────────────────────────────────
二十七、针对模型不可见的诊断 UI
────────────────────────────────

PoC 页面增加最小正式诊断能力：

- 适配视图；
- 显示 Bounds；
- 显示骨架；
- 显示模型信息；
- 查看加载诊断。

模型信息至少显示：

- Scene；
- Node；
- Mesh；
- Primitive；
- Renderable Primitive；
- Material；
- Skin；
- Joint；
- Animation；
- Bounds；
- Center；
- Radius；
- baseFitScale；
- visibility issue。

如果模型加载成功但画面空白：

自动显示一个非阻塞提示：

模型已加载，但当前视图未检测到可见几何。点击“适配视图”重新定位，或打开“加载诊断”查看原因。

不得只留空白画面。

────────────────────────────────
二十八、测试模型策略
────────────────────────────────

优先测试已有模型：

- Grace Ashcroft - Lying Pose Mobile.glb；
- test_models 中其他 GLB；
- 用户当前在模拟器中导入但不可见的模型；
- 用户当前显示“不兼容”的模型。

不得扫描整个磁盘。

如果无法自动访问用户刚选的模型：

从应用模型记录或缓存读取已导入模型。

至少覆盖：

1. Grace；
2. 一个静态无骨架 GLB；
3. 一个 Skin 模型；
4. 一个骨骼名称不标准的模型；
5. 一个无 default scene 的模型 fixture；
6. 一个 node.matrix 模型 fixture；
7. 一个原点偏移模型；
8. 一个极小模型；
9. 一个极大模型；
10. 一个透明材质模型；
11. 一个负 scale 模型；
12. 一个 skin.skeleton 缺失但 joints 合法的模型；
13. 一个有 Skin 但自动人形名称匹配失败的模型。

允许生成小型 GLB fixture。

不要把用户大模型加入源码仓库。

────────────────────────────────
二十九、单元测试：可见性
────────────────────────────────

至少增加：

1. 默认 scene 存在；
2. scene 字段缺失回退 scene[0]；
3. 多 root node；
4. node.matrix；
5. TRS；
6. 父子 world transform；
7. local Bounds 转 world Bounds；
8. accessor 无 min/max；
9. quantized POSITION；
10. 原点偏移；
11. 极小模型；
12. 极大模型；
13. bounds NaN；
14. bounds radius 0；
15. camera target；
16. near/far；
17. baseFitScale 有限；
18. fit view 后模型中心归零；
19. scale 不重复应用；
20. offset 不重复应用。

────────────────────────────────
三十、单元测试：兼容性分层
────────────────────────────────

测试：

1. 标准静态模型：
   - geometry Supported；
   - skeleton NotPresent；
   - motion Unsupported；
2. Skin 模型但名称不标准：
   - geometry Supported；
   - skeleton Supported；
   - autoMapping NeedsManualMapping；
3. 自动匹配完整：
   - autoMapping AutoMapped；
4. 自动匹配部分：
   - PartiallyMapped；
5. 手动匹配完成：
   - ManualMapped；
6. Skin 数据损坏：
   - skin Unsupported；
7. 不支持 required extension：
   - sceneLoadable Unsupported；
8. 材质不支持但几何可显示：
   - geometry Supported；
   - material PartiallySupported。

必须验证：

自动映射失败不会将 geometryRenderable 改成 Unsupported。

────────────────────────────────
三十一、单元测试：骨骼自动匹配
────────────────────────────────

覆盖常见命名：

- Mixamo；
- Blender；
- Unity Humanoid；
- Bip01；
- 左右下划线；
- 左右点号；
- namespace；
- 全大写；
- 全小写；
- 中文或非标准名称；
- twist bone；
- helper bone；
- 多段 spine；
- 无 shoulder；
- 无 toe；
- 反向 X 轴。

验证：

- 名称归一化；
- 左右识别；
- 层级关系；
- 候选评分；
- 低置信度不自动接受；
- 同一 Bone 不重复匹配；
- 必需与可选关节区分。

────────────────────────────────
三十二、单元测试：手动映射
────────────────────────────────

覆盖：

1. 保存一个关节；
2. 替换关节；
3. 取消关节；
4. 重复 source bone；
5. 缺少必需关节；
6. 缺少可选关节；
7. 左右反转；
8. Arm 层级错误；
9. Leg 层级错误；
10. Head 不在 Spine 链；
11. sourceNodeIndex 越界；
12. skeletonHash 变化；
13. 模型重新导入后映射复用；
14. 模型变化后要求重新验证；
15. 保存并重新读取；
16. 清空映射；
17. 自动映射后手动修正；
18. 对称骨骼建议。

────────────────────────────────
三十三、模拟器实际验收
────────────────────────────────

用户已经连接模拟器。

执行：

1. hdc list targets；
2. 确认模拟器；
3. entry@default 增量构建；
4. 构建 Debug HAP；
5. 覆盖安装，保留数据；
6. 启动应用；
7. 进入动作管理；
8. 进入导入模型；
9. 导入一个现有模型；
10. 打开 PoC；
11. 截图；
12. 检查是否为空白；
13. 点击适配视图；
14. 检查 Bounds；
15. 打开骨架显示；
16. 检查 hilog；
17. 查看能力报告；
18. 查看“不兼容”具体原因；
19. 如果 Skin 存在但自动匹配失败：
    进入骨骼映射；
20. 至少手动映射：
    - Hips；
    - Spine；
    - Head；
    - 左上臂；
    - 左前臂；
    - 左手；
    - 右上臂；
    - 右前臂；
    - 右手；
    - 左大腿；
    - 左小腿；
    - 左脚；
    - 右大腿；
    - 右小腿；
    - 右脚；
21. 验证映射；
22. 保存；
23. 退出页面；
24. 重新进入；
25. 确认映射仍存在；
26. 检查模型卡片状态变为：
    已完成骨骼映射；
27. 如果有简单测试动作：
    运行上臂旋转测试；
28. 恢复 rest pose；
29. 截图；
30. 检查 hilog。

如果 UI 自动化无法完成所有关节选择：

可以：

- 自动调用 ViewModel 映射方法；
- 使用生成 fixture 骨架；
- 但必须至少人工 UI 或自动化完成一次真实页面保存流程。

不得虚构完整模型映射已在真实用户模型上完成。

────────────────────────────────
三十四、日志
────────────────────────────────

保留低频日志：

- model visibility analysis；
- selected scene；
- renderable mesh count；
- bounds summary；
- camera summary；
- compatibility summary；
- skeleton detected；
- auto mapping result；
- manual mapping saved；
- validation result。

禁止逐帧输出：

- world matrix；
- pointer；
- bone position；
- camera；
- scale；
- every node。

敏感信息不得输出：

- 完整绝对路径；
- 完整 SHA；
- 用户聊天；
- 模型完整 JSON；
- 二进制内容。

重点检查：

- FATAL；
- SIGSEGV；
- abort；
- TypeError；
- Scene disposed；
- invalid matrix；
- NaN；
- Infinity；
- out of range；
- skin；
- joint；
- inverse bind；
- camera；
- bounds；
- unsupported extension；
- material compile；
- ArkGraphics parse。

────────────────────────────────
三十五、性能
────────────────────────────────

不得在每帧：

- 重新扫描 glTF JSON；
- 重新计算 skeletonHash；
- 重新读取 GLB；
- 重新计算全部自动匹配候选；
- 写数据库；
- 创建骨骼树；
- 输出所有骨骼日志。

允许：

- 模型加载时计算一次；
- 打开骨骼映射页面时建立一次骨骼索引；
- 骨架 overlay 每帧只更新必要世界位置；
- 映射修改时局部刷新。

Grace 有 524 joints。

骨骼树和骨架显示必须能处理至少 524 joints。

要求：

- 页面不明显卡死；
- 搜索可用；
- 展开大型骨骼树不一次性创建无数复杂组件；
- 优先 LazyForEach 或项目等价方案；
- 高亮选择不重建 Scene。

────────────────────────────────
三十六、数据持久化
────────────────────────────────

骨骼映射与模型记录关联。

保存字段：

- modelId；
- sourceSha256；
- skeletonHash；
- profileVersion；
- mapping；
- alignment；
- validation；
- updatedAt。

不得只按文件名关联。

同内容不同文件名：

可以复用映射。

同文件名但内容改变：

不得错误复用。

删除模型记录时：

按现有项目策略处理映射数据。

如果模型重新导入但 SHA 相同：

允许恢复映射。

如果 skeletonHash 不同：

标记：

需要重新验证。

────────────────────────────────
三十七、构建规则
────────────────────────────────

执行：

1. 可见性相关单元测试；
2. 兼容性相关单元测试；
3. 骨骼匹配测试；
4. 手动映射测试；
5. host-side GLB 验证；
6. entry@default 增量构建；
7. Debug HAP 构建；
8. 覆盖安装；
9. 模拟器验收；
10. hilog 检查；
11. 截图；
12. Debug 代码清理；
13. 再次增量构建；
14. 最终 smoke test。

默认禁止 clean。

只有：

- Native 配置改变；
- CMake 改变；
- 连续两次明确缓存错误；

才允许 clean。

同一失败命令不要无意义执行超过两次。

每次重试必须有新修复或新证据。

────────────────────────────────
三十八、Debug 清理
────────────────────────────────

测试完成后删除：

- 自动导入固定路径；
- 自动映射固定 Bone；
- 临时模型 ID；
- 自动打开页面；
- Debug-only 测试按钮；
- 逐节点日志；
- 逐骨骼日志；
- 临时 rawfile 大模型；
- 临时骨架 fixture UI。

可以保留正式功能：

- 适配视图；
- 显示骨架；
- 模型诊断；
- 骨骼映射页面；
- 自动匹配；
- 手动匹配；
- 验证；
- 保存；
- 单元测试；
- 小型 fixture。

不要删除历史正式测试基础设施，除非确认它只是无调用者的临时代码。

────────────────────────────────
三十九、TODO.md
────────────────────────────────

完成后在 TODO.md 末尾追加：

## T-3D.6E 模型不可见诊断、兼容性分层与手动人形骨骼映射

### 原始问题

记录：

- 导入成功但画面空白；
- 其他 GLB 查看器可显示；
- Blender 可见骨架；
- ArkTavern 显示不兼容；
- 当前判断条件。

### 模型不可见根因

必须写真实根因。

例如：

- Scene 未正确选择；
- ModelRoot 未挂载；
- Bounds 未应用 world transform；
- baseFitScale 异常；
- Camera 未指向模型；
- 材质全透明；
- Skin 矩阵异常；
- 动画移动模型；
- 其他。

不得写“可能”。

### 修复内容

记录：

- Scene；
- Node；
- Matrix；
- Bounds；
- Camera；
- Material；
- Skin；
- Animation；
- 自动取景；
- 适配视图。

### 兼容性分层

记录：

- 模型显示；
- 材质；
- 纹理；
- 骨架；
- 动画；
- 自动人形映射；
- 手动人形映射；
- 动作重定向。

### 原“不兼容”判定

记录：

- 原文件；
- 原方法；
- 原条件；
- 为什么过严；
- 如何拆分。

### 自动映射

记录：

- 名称匹配；
- 层级匹配；
- 左右判断；
- 空间评分；
- 置信度；
- 候选。

### 手动映射

记录：

- 页面；
- 标准关节；
- 骨骼树；
- 高亮；
- 保存；
- 验证；
- skeletonHash。

### 模型校准

记录：

- 朝向；
- 中心；
- 单位；
- 地面；
- rest pose。

### 测试

记录：

- 可见性测试；
- 兼容性测试；
- 自动匹配测试；
- 手动匹配测试；
- Grace；
- 其他模型；
- 模拟器；
- hilog；
- 截图。

### 已知限制

例如：

- 尚未完成动作重定向；
- 尚未完成 3D Bone picking；
- 尚未实现 IK；
- 某些材质扩展；
- 模拟器与真机 GPU 差异。

### 结论

只有满足以下条件才写完成：

1. 至少一个原来空白的模型能够定位或得到明确不可见原因；
2. 模型显示与动作兼容状态已拆分；
3. Skin 存在但名称不标准时不再显示整体不兼容；
4. 手动映射可以保存和重新读取；
5. 必需关节验证存在；
6. entry@default 构建成功；
7. 模拟器至少完成一次实际页面验收；
8. 无 FATAL。

否则写：

实现进行中，记录未完成项。

────────────────────────────────
四十、最终报告
────────────────────────────────

完成后只报告：

1. 原模型导入和显示调用链；
2. 原兼容性判断调用链；
3. 模型空白的真实根因；
4. “当前模型不兼容”的真实根因；
5. 修改文件；
6. Scene 选择结果；
7. Node transform 结果；
8. Bounds 结果；
9. Camera 结果；
10. Material 结果；
11. Skin 结果；
12. Animation 结果；
13. 自动取景结果；
14. 适配视图结果；
15. 新能力报告结构；
16. 骨架存在判断；
17. 自动骨骼匹配结果；
18. 自动匹配置信度；
19. 手动映射页面；
20. 手动映射保存；
21. 映射验证；
22. skeletonHash；
23. 模型校准；
24. Grace 结果；
25. 用户已导入模型结果；
26. entry@default；
27. 单元测试；
28. HAP 路径；
29. 覆盖安装；
30. 模拟器结果；
31. hilog；
32. 截图路径；
33. TODO.md 行号；
34. 已知限制；
35. 下一步动作重定向入口。

完成后停止。

不得开始：

- 完整动作重定向；
- IK；
- 动画时间轴；
- 完整独立模型查看器；
- 材质编辑；
- 灯光编辑；
- 模型截图；
- 聊天动作联动。