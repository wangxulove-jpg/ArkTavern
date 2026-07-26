# REMOVE_3D_DISPLAY_PLAN

完整移除 ArkTavern 3D 展示子系统的删除清单与执行计划。

## 初始 Git 状态(任务开始前)

```
Branch : ui/home-foundation
HEAD   : 8e319b57efca4bdd42cd054ef66df1977d5fcc61
```

已存在变更:
- Staged:大量 3D 测试模型 / 截图 / 日志的删除,以及 `.gitignore`、`CLEANUP_DRY_RUN.md`、`Character3DPocPage.ets` / `Character3DService.ets` / `Character3DPocViewModel.ets` 的修改
- Unstaged:`AvatarLibraryPage.ets`、`AvatarLibraryService.ets`、`Model3DAssetStore.ets` 的修改
- Untracked:`PHASE2_VRM_ONLY_REPORT.md`、`VrmAvatarValidator.ets`、`VrmAvatarValidatorTest.ets`

本任务严格禁止 `git reset` / `git restore` / `git clean` / `git stash` 等破坏性 Git 操作,所有删除通过文件系统操作完成。

---

## DELETE - 3D 专属文件(整体删除)

### A. 动作、重定向、诊断系统(Service 层)

| 文件 | 主要职责 |
|---|---|
| entry/src/main/ets/services/HumanoidRetargetor.ets | Humanoid 重定向核心 |
| entry/src/main/ets/services/HumanoidRetargetPlaybackController.ets | 重定向回放控制器 |
| entry/src/main/ets/services/HumanoidMotionSampler.ets | 动作采样器 |
| entry/src/main/ets/services/HumanoidProvider.ets | Humanoid 数据提供者 |
| entry/src/main/ets/services/TargetRestPoseCollector.ets | Target Rest Pose 收集 |
| entry/src/main/ets/services/TargetAvatarSkeletonController.ets | Target Avatar 骨架控制 |
| entry/src/main/ets/services/SceneNodeCollector.ets | 3D SceneNode 收集 |
| entry/src/main/ets/services/SourceRetargetDiagnosticCollector.ets | 重定向诊断收集 |
| entry/src/main/ets/services/SourceTargetCompareSkeleton.ets | Source/Target 骨架对比 |
| entry/src/main/ets/services/SurfaceBonePickingService.ets | 表面骨骼拾取 |
| entry/src/main/ets/services/RestPoseClassifier.ets | Rest Pose 分类 |
| entry/src/main/ets/services/AvatarOrientationAnalyzer.ets | Avatar 方向分析 |
| entry/src/main/ets/services/Character3DActionService.ets | 3D 动作资产管理 |
| entry/src/main/ets/services/Character3DAnimationController.ets | 3D 动画控制 |
| entry/src/main/ets/services/Character3DModelCompatibilityService.ets | 3D 模型兼容性(meshopt) |
| entry/src/main/ets/services/Character3DService.ets | 3D 模型导入与持久化 |
| entry/src/main/ets/services/AvatarLibraryService.ets | VRM Avatar 模型库业务服务 |
| entry/src/main/ets/services/AvatarChangeEvent.ets | Avatar 变更事件分发 |
| entry/src/main/ets/services/ActionDisplayPreferenceStore.ets | 动作显示偏好 |
| entry/src/main/ets/services/ActionPlaybackPreferenceStore.ets | 动作回放偏好 |

### B. 3D 页面 / 组件 / ViewModel

| 文件 | 主要职责 |
|---|---|
| entry/src/main/ets/pages/Character3DPocPage.ets | 3D PoC 页面 |
| entry/src/main/ets/pages/Character3DActionManagerPage.ets | 3D 动作管理页 |
| entry/src/main/ets/pages/HumanoidMappingPage.ets | 骨骼映射页 |
| entry/src/main/ets/pages/AvatarLibraryPage.ets | VRM Avatar 模型库页 |
| entry/src/main/ets/components/ActionAvatarPreview3D.ets | 3D 动作预览宿主 |
| entry/src/main/ets/components/ActionPreviewCanvas.ets | 动作预览 Canvas |
| entry/src/main/ets/components/Character3DPanel.ets | 聊天页 3D 面板 |
| entry/src/main/ets/components/StableActionPreview3DHost.ets | 稳定 3D 预览宿主 |
| entry/src/main/ets/viewmodels/ActionAvatarPreviewViewModel.ets | 3D 动作预览 VM |
| entry/src/main/ets/viewmodels/AvatarLibraryViewModel.ets | VRM 模型库 VM |
| entry/src/main/ets/viewmodels/Character3DActionManagerViewModel.ets | 3D 动作管理 VM |
| entry/src/main/ets/viewmodels/Character3DPanelViewModel.ets | 3D 面板 VM |
| entry/src/main/ets/viewmodels/Character3DPocViewModel.ets | 3D PoC VM |
| entry/src/main/ets/viewmodels/HumanoidMappingViewModel.ets | 骨骼映射 VM |
| entry/src/main/ets/viewmodels/ActionCardDataSource.ets | 动作卡片数据源 |

### C. 3D Store / Model / Parser / Util

| 文件 | 主要职责 |
|---|---|
| entry/src/main/ets/storage/AvatarLibraryStore.ets | VRM 模型库元数据 |
| entry/src/main/ets/storage/AvatarOrientationCalibrationStore.ets | Avatar 方向校准 |
| entry/src/main/ets/storage/HumanoidMappingStore.ets | 骨骼映射存储 |
| entry/src/main/ets/storage/Model3DAssetStore.ets | 3D 模型文件存储 |
| entry/src/main/ets/storage/VrmMetaStore.ets | VRM 元数据存储 |
| entry/src/main/ets/models/character3d/ (整个目录) | 3D 数据模型(VrmAsset/VrmHumanoid/HumanoidBone/Character3DActionAsset 等) |
| entry/src/main/ets/parser/GlbContainerValidator.ets | GLB 容器校验 |
| entry/src/main/ets/parser/GltfAnimationDataParser.ets | glTF 动画数据解析 |
| entry/src/main/ets/parser/GltfAnimationParser.ets | glTF 动画解析 |
| entry/src/main/ets/parser/GltfBoundsCalculator.ets | glTF 包围盒 |
| entry/src/main/ets/parser/GltfSemanticValidator.ets | glTF 语义校验 |
| entry/src/main/ets/parser/GltfSkinMaterialAnalyzer.ets | glTF Skin/Material 分析 |
| entry/src/main/ets/parser/GltfValidator.ets | glTF 校验 |
| entry/src/main/ets/parser/GltfVertexAccessor.ets | glTF Vertex Accessor |
| entry/src/main/ets/parser/ModelExtensionCompatibilityRegistry.ets | 模型扩展兼容注册 |
| entry/src/main/ets/parser/ModelImportDiagnostics.ets | 模型导入诊断 |
| entry/src/main/ets/parser/ModelInspector.ets | 模型检查器 |
| entry/src/main/ets/parser/VRMImporter.ets | VRM 导入器 |
| entry/src/main/ets/parser/VrmAvatarValidator.ets | VRM Avatar 校验 |
| entry/src/main/ets/parser/VrmBoneKeyParser.ets | VRM Bone Key 解析 |
| entry/src/main/ets/parser/VrmDetector.ets | VRM 检测 |
| entry/src/main/ets/parser/VrmExpressionParser.ets | VRM 表情解析 |
| entry/src/main/ets/parser/VrmExtensionParser.ets | VRM 扩展解析 |
| entry/src/main/ets/parser/VrmFirstPersonParser.ets | VRM FirstPerson 解析 |
| entry/src/main/ets/parser/VrmHumanoidMapper.ets | VRM Humanoid 映射 |
| entry/src/main/ets/parser/VrmHumanoidResolver.ets | VRM Humanoid 解析 |
| entry/src/main/ets/parser/VrmLookAtParser.ets | VRM LookAt 解析 |
| entry/src/main/ets/parser/VrmMetaExtractor.ets | VRM Meta 提取 |
| entry/src/main/ets/parser/VrmSpringBoneParser.ets | VRM SpringBone 解析 |
| entry/src/main/ets/utils/Chat3DDisplaySettings.ets | 聊天页 3D 显示开关 |
| entry/src/main/ets/utils/QuaternionUtil.ets | 四元数工具 |
| entry/src/main/ets/utils/SceneNodeTransformUtil.ets | SceneNode 变换工具 |

### D. 3D 资源 / Native / 工具

| 文件/目录 | 主要职责 |
|---|---|
| entry/src/main/resources/rawfile/actions/ (整个目录) | 内置动作包 + 预览模型 |
| entry/src/main/resources/rawfile/vrm_samples/ (整个目录) | VRM 样例文件 |
| entry/src/main/cpp/model_converter/ (整个目录) | meshopt GLB 解码 C++ |
| entry/src/main/cpp/third_party/meshoptimizer_src/ (整个目录) | meshoptimizer 第三方源码 |
| entry/src/main/cpp/types/libmodel_converter/ (整个目录) | NAPI 类型声明 |
| entry/src/main/cpp/CMakeLists.txt | 3D native 构建配置 |
| entry/src/main/cpp/napi_init.cpp | model_converter NAPI 注册 |
| tools/blender/ (整个目录) | Blender 动作生成脚本 |
| tools/model_converter_cli/ (整个目录) | 模型转换 CLI |
| tools/model_import_validation/ (整个目录) | GLB 校验脚本 |
| tools/parse_action_pack.js | 动作包解析脚本 |

### E. 3D 测试

| 文件 | 主要职责 |
|---|---|
| entry/src/main/ets/test/AvatarOrientationCalibrationTest.ets | 方向校准测试 |
| entry/src/main/ets/test/Character3DDisplayConfigTest.ets | 3D 显示配置测试 |
| entry/src/main/ets/test/Character3DGestureHandlerTest.ets | 3D 手势测试 |
| entry/src/main/ets/test/Chat3DPanelTest.ets | 聊天 3D 面板测试 |
| entry/src/main/ets/test/GlbContainerAndSemanticTest.ets | GLB 容器/语义测试 |
| entry/src/main/ets/test/HumanoidMappingTest.ets | 骨骼映射测试 |
| entry/src/main/ets/test/ModelVisibilityTest.ets | 模型可见性测试 |
| entry/src/main/ets/test/RestPoseClassifierTest.ets | Rest Pose 测试 |
| entry/src/main/ets/test/RetargetInvariantTest.ets | Retarget 不变量测试 |
| entry/src/main/ets/test/SceneNodeTransformUtilTest.ets | SceneNode 变换测试 |
| entry/src/main/ets/test/SurfaceBonePickingTest.ets | 表面骨骼拾取测试 |
| entry/src/main/ets/test/VrmAvatarValidatorTest.ets | VRM Avatar 校验测试 |
| entry/src/main/ets/test/VrmHumanoidPipelineTest.ets | VRM Humanoid 流水线测试 |
| entry/src/main/ets/test/VrmParserTest.ets | VRM 解析测试 |

### F. 3D 文档(整体删除)

| 文件 | 处理 |
|---|---|
| 3D_DISPLAY_FULL_AUDIT.md | DELETE - 已废弃审计 |
| CLEANUP_DRY_RUN.md | DELETE - 已废弃 dry run(已 staged) |
| PHASE2_VRM_ONLY_REPORT.md | DELETE - 已废弃阶段报告 |
| T-3D.6E.md | DELETE - 3D 任务文档 |
| T3D.6D.md | DELETE - 3D 任务文档 |

---

## EDIT - 含 3D 引用的混合文件(局部删除)

| 文件 | 需要移除的 3D 引用 |
|---|---|
| entry/src/main/ets/services/AppServices.ets | 8 个 import / 6 个字段 / 构造函数中 chat3DDisplaySettings 实例化 / initialize() 中 5 个 3D Service 创建与注入 / 6 个静态 getter / createHumanoidMappingViewModel 工厂方法 |
| entry/src/main/ets/pages/ChatPage.ets | Character3DPanel import + getZoomFactor import + 3D 状态字段 + Character3DPanel({...}) 渲染块 + 3D 菜单/保存/重置处理器 + Chat3DDisplaySettings 调用 |
| entry/src/main/ets/pages/AppSettingsPage.ets | Chat3DDisplaySettings + ModelConversionMode import + chat3DEnabled/chat3DSettings/modelConversionMode 字段 + toggleChat3D/loadModelConversionMode/changeModelConversionMode 方法 + 对应 UI 行 |
| entry/src/main/ets/pages/tabs/SettingsRootView.ets | "3D 渲染 PoC" 入口卡片(约 103-109 行) |
| entry/src/main/ets/pages/tabs/CharacterRootView.ets | "动作管理(测试)" 按钮及跳转(约 333-344 行) |
| entry/src/main/ets/components/ChatMoreMenuSheet.ets | Character3DDisplayConfig import + 3D 模型开关行 + 相关注释 |
| entry/src/main/resources/base/profile/main_pages.json | 4 个 3D 页面路由 |
| automation/ui/ark_tavern_ui_map.json | 4 个页面入口(Character3DPocPage/Character3DActionManagerPage/HumanoidMappingPage/AvatarLibraryPage)及子 componentId |
| entry/build-profile.json5 | externalNativeOptions 块(仅服务于 model_converter native 模块) |

---

## KEEP - 已验证无 3D 引用(保持不动)

| 文件 | 状态 |
|---|---|
| entry/src/main/ets/models/Character.ets | 纯 2D 角色卡模型,无 3D 字段 |
| entry/src/main/ets/entryability/EntryAbility.ets | 仅调用 AppServices.initialize |
| entry/src/main/ets/entrybackupability/EntryBackupAbility.ets | 无 3D 引用 |
| entry/src/main/ets/pages/Index.ets | 仅 Tab 装配,无 3D 引用 |
| entry/src/main/ets/pages/CharacterEditPage.ets | 无 3D 引用 |
| entry/src/main/ets/pages/CharacterListPage.ets | 无 3D 引用 |
| entry/src/main/ets/pages/WorldChatPage.ets | 无 3D 引用 |
| entry/src/main/ets/pages/tabs/ChatSessionRootView.ets | 无 3D 引用 |
| entry/src/main/ets/pages/tabs/MarketPage.ets | 无 3D 引用 |
| entry/src/main/ets/viewmodels/ChatViewModel.ets | 无 3D 引用 |
| entry/src/main/ets/viewmodels/CharacterEditViewModel.ets | 无 3D 引用 |
| entry/src/main/ets/viewmodels/CharacterListViewModel.ets | 无 3D 引用 |
| entry/src/main/ets/services/CharacterService.ets | 无 3D 引用 |
| entry/src/main/ets/services/ChatService.ets | 无 3D 引用 |
| entry/src/main/ets/services/MultiPersonChatService.ets | 无 3D 引用 |
| entry/src/main/ets/services/WorldService.ets | 无 3D 引用 |
| entry/src/main/ets/repositories/* | 全部仓储无 3D 引用 |
| entry/src/main/ets/database/* | 数据库层无 3D 引用 |
| entry/src/main/ets/network/* | 网络层无 3D 引用 |
| entry/src/main/ets/storage/AppPreferences.ets | 通用 KV,3D 与非 3D 共用,保留 |
| entry/src/main/ets/storage/CharacterAssetStore.ets | 2D 角色头像资产,保留 |
| entry/src/main/ets/storage/CharacterStore.ets | 2D 角色持久化,保留 |
| entry/src/main/ets/storage/CharacterSelectionStore.ets | 2D 角色选择,保留 |
| entry/src/main/resources/base/element/string.json | 无 3D 字符串资源 |
| entry/src/main/module.json5 | 无 3D 配置 |
| entry/oh-package.json5 | 无 3D 依赖 |
| oh-package.json5 (根) | 无 3D 依赖 |
| hvigor/hvigor-config.json5 | 无 3D 配置 |
| build-profile.json5 (根) | 无 3D 配置 |

---

## UNCERTAIN - 无法确认用途(不删除)

无。所有文件经扫描后均可明确归类为 DELETE / EDIT / KEEP。

---

## 执行批次

### Batch A:删除动作、重定向、诊断系统
- 删除 A 节全部 Service 文件
- 增量编译,修复错误

### Batch B:删除 3D 页面、组件、ViewModel
- 删除 B 节全部 Page / Component / ViewModel
- 同步移除 main_pages.json 4 个路由
- 同步移除 ark_tavern_ui_map.json 4 个页面入口
- 增量编译,修复错误

### Batch C:删除 3D Service、Store、Model、Parser
- 删除 A 节剩余 Service(Character3DService/AvatarLibraryService/AvatarChangeEvent/Character3DActionService/Character3DAnimationController/Character3DModelCompatibilityService/ActionDisplayPreferenceStore/ActionPlaybackPreferenceStore)
- 删除 C 节全部 Store / Model / Parser / Util
- 编辑 AppServices.ets 移除全部 3D 引用
- 编辑 ChatPage.ets / AppSettingsPage.ets / SettingsRootView.ets / CharacterRootView.ets / ChatMoreMenuSheet.ets 移除 3D 引用
- 增量编译,修复错误

### Batch D:删除资源、依赖和配置
- 删除 D 节全部资源、Native、工具
- 编辑 entry/build-profile.json5 移除 externalNativeOptions
- 删除 E 节全部 3D 测试
- 删除 F 节全部 3D 文档
- 增量编译,修复错误

### Batch E:非 3D 功能回归
- 验证角色卡、单人聊天、多人聊天、应用启动
- 全仓最终扫描 3D 关键字
