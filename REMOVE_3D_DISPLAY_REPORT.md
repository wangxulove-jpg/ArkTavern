# ArkTavern 3D 展示子系统移除最终报告

> 生成时间:2026-07-26
> 任务:完整移除项目中现有的 3D 模型导入、3D 模型展示、VRM/GLB/GLTF/VRMA 支持、3D Avatar 管理、动作系统、动作重定向、骨骼映射、骨架可视化、Component3D、ArkGraphics3D 使用、3D 调试与诊断、3D 测试与资源。
> 任务边界:仅删除,不重新实现。完成后项目暂时不具备任何 3D 展示或 3D 文件导入能力。

---

## 一、开始前状态保护

执行命令采集的初始 Git 状态:

```text
git branch --show-current: ui/home-foundation
git rev-parse HEAD:       8e319b57efca4bdd42cd054ef66df1977d5fcc61
```

仓库当时包含 Phase 1 staged 变更与 Phase 2 unstaged/untracked 变更。
执行过程中严格未使用 `git reset`、`git restore`、`git checkout --`、`git clean`、`git stash`、强制切换分支、覆盖已有未提交修改、自动提交或修改 Git 历史。

---

## 二、总体删除规模

| 指标 | 数值 |
| --- | --- |
| 删除文件总数 | 217 |
| 修改文件总数 | 15 |
| 新增归档文档 | 7 |
| 净删除代码行数 | 74231 deletions / 17 insertions (166 files changed in diff stat) |
| 删除资源大小 | 约 21.6 MB(含 VRM 样例 4 个、GLB 测试模型 5 个、内置动作包 GLB+JSON+LICENSE+SOURCE、test_models/generated/* 18 个、meshoptimizer 第三方源码、CPP native 模块等) |

### git status 分类汇总

```text
deletedStaged   (D )  : 65
deletedUnstaged ( D)  : 148
MD (modified in index, deleted in working tree): 3
AD (added in index, deleted in working tree)   : 1
modifiedStaged   (M ): 1
modifiedUnstaged ( M): 14
untracked        (??): 7
```

---

## 三、删除清单(分类)

### 3.1 删除的页面 (Pages)

```text
entry/src/main/ets/pages/AvatarLibraryPage.ets
entry/src/main/ets/pages/Character3DActionManagerPage.ets
entry/src/main/ets/pages/Character3DPocPage.ets          (MD - 原已 staged 修改,本次彻底删除)
entry/src/main/ets/pages/HumanoidMappingPage.ets
```

对应路由(已从 `main_pages.json` 移除):`pages/AvatarLibraryPage`、`pages/Character3DActionManagerPage`、`pages/Character3DPocPage`、`pages/HumanoidMappingPage`。

### 3.2 删除的组件 (Components)

```text
entry/src/main/ets/components/ActionAvatarPreview3D.ets
entry/src/main/ets/components/ActionPreviewCanvas.ets
entry/src/main/ets/components/Character3DPanel.ets
entry/src/main/ets/components/StableActionPreview3DHost.ets
```

### 3.3 删除的 ViewModel

```text
entry/src/main/ets/viewmodels/ActionAvatarPreviewViewModel.ets
entry/src/main/ets/viewmodels/ActionCardDataSource.ets
entry/src/main/ets/viewmodels/AvatarLibraryViewModel.ets
entry/src/main/ets/viewmodels/Character3DActionManagerViewModel.ets
entry/src/main/ets/viewmodels/Character3DPanelViewModel.ets
entry/src/main/ets/viewmodels/Character3DPocViewModel.ets       (MD)
entry/src/main/ets/viewmodels/HumanoidMappingViewModel.ets
```

### 3.4 删除的 Service

```text
entry/src/main/ets/services/ActionDisplayPreferenceStore.ets
entry/src/main/ets/services/ActionPlaybackPreferenceStore.ets
entry/src/main/ets/services/AvatarChangeEvent.ets
entry/src/main/ets/services/AvatarLibraryService.ets
entry/src/main/ets/services/AvatarOrientationAnalyzer.ets
entry/src/main/ets/services/Character3DActionService.ets
entry/src/main/ets/services/Character3DAnimationController.ets
entry/src/main/ets/services/Character3DModelCompatibilityService.ets
entry/src/main/ets/services/Character3DService.ets              (MD)
entry/src/main/ets/services/HumanoidMotionSampler.ets
entry/src/main/ets/services/HumanoidProvider.ets
entry/src/main/ets/services/HumanoidRetargetPlaybackController.ets
entry/src/main/ets/services/HumanoidRetargetor.ets
entry/src/main/ets/services/RestPoseClassifier.ets
entry/src/main/ets/services/SceneNodeCollector.ets
entry/src/main/ets/services/SourceRetargetDiagnosticCollector.ets
entry/src/main/ets/services/SourceTargetCompareSkeleton.ets
entry/src/main/ets/services/SurfaceBonePickingService.ets
entry/src/main/ets/services/TargetAvatarSkeletonController.ets
entry/src/main/ets/services/TargetRestPoseCollector.ets
```

### 3.5 删除的 Store (Storage)

```text
entry/src/main/ets/storage/AvatarLibraryStore.ets
entry/src/main/ets/storage/AvatarOrientationCalibrationStore.ets
entry/src/main/ets/storage/HumanoidMappingStore.ets
entry/src/main/ets/storage/Model3DAssetStore.ets
entry/src/main/ets/storage/VrmMetaStore.ets
```

### 3.6 删除的 Model 与类型

```text
entry/src/main/ets/models/character3d/ActionPreviewKeyframes.ets
entry/src/main/ets/models/character3d/AvatarAsset.ets
entry/src/main/ets/models/character3d/AvatarOrientationCalibration.ets
entry/src/main/ets/models/character3d/BoneDebugOverlay.ets
entry/src/main/ets/models/character3d/BuiltInActionManifest.ets
entry/src/main/ets/models/character3d/Character3DActionAsset.ets
entry/src/main/ets/models/character3d/Character3DActionPreviewRenderer.ets
entry/src/main/ets/models/character3d/Character3DActionSlot.ets
entry/src/main/ets/models/character3d/Character3DDisplayConfig.ets
entry/src/main/ets/models/character3d/Character3DGestureHandler.ets
entry/src/main/ets/models/character3d/Character3DLoadState.ets
entry/src/main/ets/models/character3d/DefaultHumanoidSkeleton.ets
entry/src/main/ets/models/character3d/HumanoidBone.ets
entry/src/main/ets/models/character3d/HumanoidBoneMapper.ets
entry/src/main/ets/models/character3d/HumanoidMappingValidator.ets
entry/src/main/ets/models/character3d/HumanoidMotionClip.ets
entry/src/main/ets/models/character3d/ManualHumanoidMapping.ets
entry/src/main/ets/models/character3d/ModelBounds.ets
entry/src/main/ets/models/character3d/ModelCapabilityReport.ets
entry/src/main/ets/models/character3d/ModelCompatibility.ets
entry/src/main/ets/models/character3d/ModelImportResult.ets
entry/src/main/ets/models/character3d/ModelVisibility.ets
entry/src/main/ets/models/character3d/MotionRetargetConfig.ets
entry/src/main/ets/models/character3d/SkeletonDisplayMode.ets
entry/src/main/ets/models/character3d/SurfaceBoneCandidate.ets
entry/src/main/ets/models/character3d/UnifiedActionItem.ets
entry/src/main/ets/models/character3d/vrm/VrmAsset.ets
entry/src/main/ets/models/character3d/vrm/VrmExpression.ets
entry/src/main/ets/models/character3d/vrm/VrmFirstPerson.ets
entry/src/main/ets/models/character3d/vrm/VrmHumanoid.ets
entry/src/main/ets/models/character3d/vrm/VrmLookAt.ets
entry/src/main/ets/models/character3d/vrm/VrmMeta.ets
entry/src/main/ets/models/character3d/vrm/VrmSpringBone.ets
entry/src/main/ets/models/character3d/vrm/VrmVersion.ets
```

### 3.7 删除的 Parser

```text
entry/src/main/ets/parser/GlbContainerValidator.ets
entry/src/main/ets/parser/GltfAnimationDataParser.ets
entry/src/main/ets/parser/GltfAnimationParser.ets
entry/src/main/ets/parser/GltfBoundsCalculator.ets
entry/src/main/ets/parser/GltfSemanticValidator.ets
entry/src/main/ets/parser/GltfSkinMaterialAnalyzer.ets
entry/src/main/ets/parser/GltfValidator.ets
entry/src/main/ets/parser/GltfVertexAccessor.ets
entry/src/main/ets/parser/ModelExtensionCompatibilityRegistry.ets
entry/src/main/ets/parser/ModelImportDiagnostics.ets
entry/src/main/ets/parser/ModelInspector.ets
entry/src/main/ets/parser/VRMImporter.ets
entry/src/main/ets/parser/VrmBoneKeyParser.ets
entry/src/main/ets/parser/VrmDetector.ets
entry/src/main/ets/parser/VrmExpressionParser.ets
entry/src/main/ets/parser/VrmExtensionParser.ets
entry/src/main/ets/parser/VrmFirstPersonParser.ets
entry/src/main/ets/parser/VrmHumanoidMapper.ets
entry/src/main/ets/parser/VrmHumanoidResolver.ets
entry/src/main/ets/parser/VrmLookAtParser.ets
entry/src/main/ets/parser/VrmMetaExtractor.ets
entry/src/main/ets/parser/VrmSpringBoneParser.ets
```

### 3.8 删除的 utils

```text
entry/src/main/ets/utils/Chat3DDisplaySettings.ets
entry/src/main/ets/utils/QuaternionUtil.ets
entry/src/main/ets/utils/SceneNodeTransformUtil.ets
entry/src/main/ets/utils/ShaUtil.ets
```

### 3.9 删除的测试

```text
entry/src/main/ets/test/AvatarOrientationCalibrationTest.ets
entry/src/main/ets/test/Character3DDisplayConfigTest.ets
entry/src/main/ets/test/Character3DGestureHandlerTest.ets
entry/src/main/ets/test/Chat3DPanelTest.ets
entry/src/main/ets/test/GlbContainerAndSemanticTest.ets
entry/src/main/ets/test/HumanoidMappingTest.ets
entry/src/main/ets/test/ModelVisibilityTest.ets
entry/src/main/ets/test/RestPoseClassifierTest.ets
entry/src/main/ets/test/RetargetInvariantTest.ets
entry/src/main/ets/test/SceneNodeTransformUtilTest.ets
entry/src/main/ets/test/SurfaceBonePickingTest.ets
entry/src/main/ets/test/VrmHumanoidPipelineTest.ets
entry/src/main/ets/test/VrmParserTest.ets
```

### 3.10 删除的资源

```text
entry/src/main/resources/rawfile/actions/default_ai/LICENSE.txt
entry/src/main/resources/rawfile/actions/default_ai/SOURCE.txt
entry/src/main/resources/rawfile/actions/default_ai/default_ai_action_pack.glb
entry/src/main/resources/rawfile/actions/default_ai/default_ai_action_pack.json
entry/src/main/resources/rawfile/actions/default_ai/preview_humanoid.glb
entry/src/main/resources/rawfile/vrm_samples/vrm0_alicia_solid_0.51.vrm
entry/src/main/resources/rawfile/vrm_samples/vrm1_constraint_twist.vrm
entry/src/main/resources/rawfile/vrm_samples/vrm1_mtoon_uv_animation.vrm
entry/src/main/resources/rawfile/vrm_samples/vrm1_seed_san.vrm
entry/src/main/resources/rawfile/teacher-love.glb                (staged delete)
entry/src/main/resources/rawfile/test_model.glb                  (staged delete)
entry/src/main/resources/rawfile/test_model_invalid.glb          (staged delete)
test_models/Box.glb
test_models/BoxMeshopt.glb
test_models/BoxTextured.glb
test_models/BoxTexturedMeshopt.glb
test_models/generated/01_all_zero_8bytes.glb
test_models/generated/02_wrong_magic.glb
test_models/generated/03_version_1.glb
test_models/generated/04_declared_length_ffffffff.glb
test_models/generated/05_json_chunk_length_ffffffff.glb
test_models/generated/06_json_chunk_not_aligned.glb
test_models/generated/07_json_chunk_out_of_range.glb
test_models/generated/08_first_chunk_is_bin.glb
test_models/generated/09_invalid_json.glb
test_models/generated/10_asset_version_1.glb
test_models/generated/11_bufferView_out_of_range.glb
test_models/generated/12_accessor_out_of_range.glb
test_models/generated/13_unsupported_required_extension.glb
test_models/generated/14_empty_scene.glb
test_models/generated/15_no_position.glb
test_models/generated/16_nan_bounds.glb
test_models/generated/17_extremely_small_model.glb
test_models/generated/18_extremely_large_model.glb
snapshots/layout_action_mgr.json
snapshots/layout_home.json
snapshots/v1_01_home.jpeg
snapshots/v1_02_poc_fixed.jpeg
automation/night_runs/t4_2e_closeout/* (5 个文件)
automation/screenshots/t4_2e_final/* (8 个文件)
automation/ui/phase2b/simple_dump_*.txt (8 个临时 dump)
```

### 3.11 删除的 C++ Native 模块与第三方依赖

```text
entry/src/main/cpp/CMakeLists.txt
entry/src/main/cpp/napi_init.cpp
entry/src/main/cpp/model_converter/GlbBinaryReader.cpp
entry/src/main/cpp/model_converter/GlbBinaryReader.h
entry/src/main/cpp/model_converter/GlbBinaryWriter.cpp
entry/src/main/cpp/model_converter/GlbBinaryWriter.h
entry/src/main/cpp/model_converter/GlbContainerValidator.cpp
entry/src/main/cpp/model_converter/GlbContainerValidator.h
entry/src/main/cpp/model_converter/MeshoptGlbDecoder.cpp
entry/src/main/cpp/model_converter/MeshoptGlbDecoder.h
entry/src/main/cpp/model_converter/ModelConverterNapi.cpp
entry/src/main/cpp/model_converter/ModelConverterNapi.h
entry/src/main/cpp/third_party/meshoptimizer_src/LICENSE.md
entry/src/main/cpp/third_party/meshoptimizer_src/src/allocator.cpp
entry/src/main/cpp/third_party/meshoptimizer_src/src/indexcodec.cpp
entry/src/main/cpp/third_party/meshoptimizer_src/src/meshoptimizer.h
entry/src/main/cpp/third_party/meshoptimizer_src/src/quantization.cpp
entry/src/main/cpp/third_party/meshoptimizer_src/src/vertexcodec.cpp
entry/src/main/cpp/third_party/meshoptimizer_src/src/vertexfilter.cpp
entry/src/main/cpp/types/libmodel_converter/Index.d.ts
entry/src/main/cpp/types/libmodel_converter/oh-package.json5
```

### 3.12 删除的工具脚本

```text
tools/blender/generate_default_ai_actions.py
tools/model_converter_cli/main.cpp
tools/model_import_validation/generate_glb_fixtures.py
tools/model_import_validation/verify_glb_fixtures.py
tools/parse_action_pack.js
```

### 3.13 删除的根目录临时文件与历史 3D 文档

```text
3D_DISPLAY_FULL_AUDIT.md
CLEANUP_DRY_RUN.md
T-3D.6E.md
T3D.6D.md
app_hilog.txt
diag_filter.txt
diagnostic_hilog.txt
full_hilog.txt
gen_glb.ps1
hilog_buffer.txt
hilog_snapshot.txt
live_diag.txt
live_hilog.txt
loop_5times.ps1
parse-id-text.js
parse-id-text2.js
parse-layout-2.js
parse-layout-3.js
parse-layout.js
parse-text.js
parse-text3.js
parse_layout.ps1
parse_layout.py
persist_hilog.txt
test_model.glb
```

### 3.14 删除的路由

`entry/src/main/resources/base/profile/main_pages.json` 中移除的页面注册:

```text
pages/AvatarLibraryPage
pages/Character3DActionManagerPage
pages/Character3DPocPage
pages/HumanoidMappingPage
```

### 3.15 删除的依赖

```text
entry/oh-package.json5:
  dependencies."libmodel_converter.so" (file:./src/main/cpp/types/libmodel_converter)

entry/oh-package-lock.json5:
  specifiers."libmodel_converter.so@..."
  packages."libmodel_converter.so@..."

entry/build-profile.json5:
  buildOption.externalNativeOptions (path/arguments/cppFlags/abiFilters)
```

### 3.16 新增归档文档(历史保留)

```text
docs/archive/3D_DISPLAY_FULL_AUDIT.md
docs/archive/CLEANUP_DRY_RUN.md
docs/archive/PHASE2_VRM_ONLY_REPORT.md
docs/archive/REMOVE_3D_DISPLAY_PLAN.md
docs/archive/T-3D.6E.md
docs/archive/T3D.6D.md
docs/archive/3d-action-research.md  (从 docs/3d-action-research.md 移入)
```

---

## 四、修改文件清单

| 文件 | 修改内容摘要 |
| --- | --- |
| `.gitignore` | Phase 1 阶段已有的 staged 修改(本次未触碰) |
| `AGENTS.md` | 移除 `### 动态列表` 中 AvatarLibraryPage / Character3DActionManagerPage 的引用,改为通用动态列表描述 |
| `TODO.md` | 顶部新增「已废弃章节声明 (2026-07-26)」,声明 T-3D.* / T-4.0 / T-4.1 / T-4.2* 系列任务记录仅作历史归档,不再描述项目当前能力 |
| `automation/ui/ark_tavern_ui_map.json` | 移除 4 个 3D 页面入口及子 componentId,清理 `dynamicListById` 中 3D 相关规则 |
| `entry/build-profile.json5` | 移除 `externalNativeOptions` 块(CMake 路径、abiFilters 等) |
| `entry/oh-package-lock.json5` | 清空 `specifiers` 和 `packages` 中的 `libmodel_converter.so` 条目 |
| `entry/oh-package.json5` | 移除 `dependencies."libmodel_converter.so"` |
| `entry/src/main/ets/components/ChatMoreMenuSheet.ets` | 移除 `Character3DDisplayConfig` import、3D 模型开关行、`zoomFactorSliderRow`/`panelRatioSliderRow`/`sensitivitySliderRow` 等 3D UI 及回调 |
| `entry/src/main/ets/pages/AppSettingsPage.ets` | 移除 `Chat3DDisplaySettings` 与 `ModelConversionMode` import、3D 状态字段、`toggleChat3D`/`loadModelConversionMode`/`changeModelConversionMode` 方法及对应 UI 行 |
| `entry/src/main/ets/pages/ChatPage.ets` | 移除 `Character3DPanel` 与 `getZoomFactor` import、3D 状态字段、`Character3DPanel` 渲染块、3D 菜单/保存/重置处理器 |
| `entry/src/main/ets/pages/tabs/CharacterRootView.ets` | 移除 3D 相关入口与按钮 |
| `entry/src/main/ets/pages/tabs/SettingsRootView.ets` | 移除 3D 渲染 PoC 入口与按钮 |
| `entry/src/main/ets/services/AppServices.ets` | 移除 8 个 3D import、6 个 3D Service 字段、构造函数中 `chat3DDisplaySettings` 实例化、`initialize()` 中 5 个 3D Service 创建与注入、6 个静态 getter 方法、`createHumanoidMappingViewModel` 工厂方法 |
| `entry/src/main/resources/base/element/string.json` | 移除 9 条 3D 字符串资源(`settings_chat_3d_*`、`chat_3d_*`) |
| `entry/src/main/resources/base/profile/main_pages.json` | 移除 4 条 3D 页面路由 |

---

## 五、保留的核心模块

### 5.1 角色卡模块

```text
entry/src/main/ets/models/Character.ets             (纯 2D 角色卡模型,无 3D 字段)
entry/src/main/ets/services/CharacterService.ets
entry/src/main/ets/pages/CharacterListPage.ets
entry/src/main/ets/pages/CharacterEditPage.ets
entry/src/main/ets/pages/AddCharacterPage.ets
entry/src/main/ets/pages/tabs/CharacterRootView.ets (仅移除 3D 入口,主体保留)
entry/src/main/ets/pages/AiCharacterMakerPage.ets
entry/src/main/ets/pages/AiCharacterPreviewPage.ets
```

### 5.2 单人聊天模块

```text
entry/src/main/ets/pages/ChatPage.ets                (仅移除 Character3DPanel,聊天主体保留)
entry/src/main/ets/services/ChatService.ets
entry/src/main/ets/viewmodels/ChatViewModel.ets
entry/src/main/ets/components/ChatSessionListPanel.ets
entry/src/main/ets/components/BranchListPanel.ets
entry/src/main/ets/pages/BranchMapPage.ets
entry/src/main/ets/pages/ChatBackgroundSettingsPage.ets
entry/src/main/ets/pages/MemoryManagementPage.ets
entry/src/main/ets/pages/ContextBudgetPage.ets
```

### 5.3 多人聊天模块

```text
entry/src/main/ets/pages/WorldListPage.ets
entry/src/main/ets/pages/WorldCreatePage.ets
entry/src/main/ets/pages/WorldChatPage.ets
entry/src/main/ets/pages/WorldMembersPage.ets
entry/src/main/ets/pages/WorldCharacterMemoryPage.ets
```

### 5.4 其他保留的非 3D 功能

```text
entry/src/main/ets/entryability/EntryAbility.ets     (仅调用 AppServices.initialize)
entry/src/main/ets/pages/Index.ets                    (Tab 装配)
entry/src/main/ets/pages/ModelSettingsPage.ets
entry/src/main/ets/pages/ModelConfigEditPage.ets
entry/src/main/ets/pages/AppSettingsPage.ets          (仅移除 3D 设置)
entry/src/main/ets/pages/PromptPresetListPage.ets
entry/src/main/ets/pages/PromptPresetEditPage.ets
entry/src/main/ets/pages/LorebookPage.ets
entry/src/main/ets/pages/MarketDetailPage.ets
entry/src/main/ets/storage/* (除 5 个 3D Store 外全部保留)
entry/src/main/ets/network/*
entry/src/main/ets/services/* (除 3D Service 外全部保留)
```

---

## 六、不确定而未删除的文件

无。

本次扫描中所有遇到的混合文件均通过 EDIT 方式处理(只删除其中的 3D 部分),没有无法判断用途而保留的文件。

---

## 七、构建结果

### 7.1 增量构建

```text
命令: hvigorw.js --mode project -p product=default assembleApp -p buildMode=debug --no-daemon
结果: BUILD SUCCESSFUL in 31s 89ms
退出码: 0
```

构建过程中仅出现与本次 3D 删除无关的 deprecated API 警告(`back` / `getParams` / `showToast` / `show` 等弃用提示,均为项目原有警告)。

### 7.2 模拟器安装与启动

- HAP 包:`PackageHap`、`SignHap`、`PackageApp`、`SignApp` 全部 Finished
- 应用启动:正常,首页正常显示
- 启动崩溃:无
- 3D Service 初始化错误:无(已从 `AppServices.initialize()` 中移除全部 3D Service 创建与注入)

### 7.3 角色卡回归

| 验证项 | 结果 |
| --- | --- |
| 打开角色卡列表 | 正常 |
| 打开现有角色卡 | 正常 |
| 创建测试角色卡 | 正常 |
| 编辑名称/描述 | 正常 |
| 保存后重新打开 | 正常,数据持久 |
| 普通头像显示 | 正常 |
| 删除测试角色卡 | 正常 |
| 用户原有角色卡 | 未触碰,数据完整保留 |

### 7.4 单人聊天回归

| 验证项 | 结果 |
| --- | --- |
| 从角色卡进入单人聊天 | 正常 |
| 打开已有聊天 | 正常 |
| 创建新会话 | 正常 |
| 聊天页面布局 | 正常(原 3D Panel 区域已彻底移除,无空白占位) |
| 退出后重新进入 | 正常 |
| 聊天历史 | 完整保留 |
| 用户原有聊天记录 | 未触碰 |

### 7.5 多人聊天回归

| 验证项 | 结果 |
| --- | --- |
| 打开多人聊天列表 | 正常 |
| 打开已有群聊 | 正常 |
| 进入群聊 | 正常 |
| 检查成员与历史 | 正常 |
| 用户原有群聊数据 | 未触碰 |

### 7.6 3D 功能消失验证

| 验证项 | 结果 |
| --- | --- |
| 3D 页面 | 已消失 |
| 3D 菜单 | 已消失 |
| 3D 按钮 | 已消失 |
| VRM 导入入口 | 已消失 |
| GLB 导入入口 | 已消失 |
| 动作管理 | 已消失 |
| 动作卡片 | 已消失 |
| 骨骼映射 | 已消失 |
| 3D 调试 | 已消失 |
| Component3D | 已消失 |

---

## 八、全仓残留扫描结果

### 8.1 生产 ArkTS 代码扫描

在 `entry/src/main/ets/` 下对以下关键词执行搜索(大小写不敏感):

```text
Component3D          : 0 命中
ArkGraphics3D        : 0 命中
Character3D          : 0 命中
Model3D              : 0 命中
AvatarLibrary        : 0 命中
Chat3DDisplay        : 0 命中
VRM                  : 0 命中
VRMC_vrm             : 0 命中
VRMA                 : 0 命中
GLB                  : 0 命中
GLTF                 : 0 命中
Gltf                 : 0 命中
Humanoid             : 0 命中
Retarget             : 0 命中
Skeleton             : 0 命中
BoneMapping          : 0 命中
ActionAvatar         : 0 命中
SourceActionPreview  : 0 命中
TargetAvatarSkeleton : 0 命中
```

**结论:生产 ArkTS 代码中无任何可执行的 3D 功能残留。**

### 8.2 资源文件扫描

```text
*.vrm  : 0
*.glb  : 0
*.gltf : 0
*.vrma : 0
```

### 8.3 路由扫描

```text
3D 页面路由        : 0
动作页面路由       : 0
骨骼映射页面路由   : 0
```

`main_pages.json` 当前注册的 23 个页面均为非 3D 功能页面。

### 8.4 残留分类说明

历史 3D 内容仅存在于以下位置,均不可执行:

- `docs/archive/` 下的 7 个历史归档文档(调查报告 / 计划 / 阶段总结)
- `TODO.md` 中的 `T-3D.*`、`T-4.0`、`T-4.1`、`T-4.2*` 系列任务记录(已在文件顶部统一声明已废弃)
- Git 历史中的旧提交(本任务不修改 Git 历史)

---

## 九、最终 git status --short

执行 `git status --short` 后共 236 行变更(不含本报告与 PLAN 文件本身)。

按变更类型汇总:

```text
M  .gitignore
 D 3D_DISPLAY_FULL_AUDIT.md
AD CLEANUP_DRY_RUN.md
 D T-3D.6E.md
 D T3D.6D.md
D  app_hilog.txt
D  automation/night_runs/t4_2e_closeout/action_index_facts.md
D  automation/night_runs/t4_2e_closeout/build_history.txt
D  automation/night_runs/t4_2e_closeout/hilog_filtered.txt
D  automation/night_runs/t4_2e_closeout/hilog_final.txt
D  automation/night_runs/t4_2e_closeout/run_summary.md
D  automation/screenshots/t4_2e_final/*.jpeg (8 个)
D  automation/screenshots/t4_2e_final/*.png  (3 个)
 M automation/ui/ark_tavern_ui_map.json
D  diag_filter.txt
D  diagnostic_hilog.txt
 M entry/build-profile.json5
 M entry/oh-package-lock.json5
 M entry/oh-package.json5
 D entry/src/main/cpp/** (21 个文件)
 D entry/src/main/ets/components/ActionAvatarPreview3D.ets
 D entry/src/main/ets/components/ActionPreviewCanvas.ets
 D entry/src/main/ets/components/Character3DPanel.ets
 M entry/src/main/ets/components/ChatMoreMenuSheet.ets
 D entry/src/main/ets/components/StableActionPreview3DHost.ets
 D entry/src/main/ets/models/character3d/** (33 个文件)
 M entry/src/main/ets/pages/AppSettingsPage.ets
 D entry/src/main/ets/pages/AvatarLibraryPage.ets
 D entry/src/main/ets/pages/Character3DActionManagerPage.ets
MD entry/src/main/ets/pages/Character3DPocPage.ets
 M entry/src/main/ets/pages/ChatPage.ets
 D entry/src/main/ets/pages/HumanoidMappingPage.ets
 M entry/src/main/ets/pages/tabs/CharacterRootView.ets
 M entry/src/main/ets/pages/tabs/SettingsRootView.ets
 D entry/src/main/ets/parser/** (22 个文件)
 D entry/src/main/ets/services/** (20 个 3D Service)
 M entry/src/main/ets/services/AppServices.ets
 D entry/src/main/ets/storage/AvatarLibraryStore.ets 等 5 个 3D Store
 D entry/src/main/ets/test/** (13 个 3D 测试)
 D entry/src/main/ets/utils/Chat3DDisplaySettings.ets 等 4 个 3D utils
 D entry/src/main/ets/viewmodels/** (7 个 3D ViewModel)
 M entry/src/main/resources/base/element/string.json
 M entry/src/main/resources/base/profile/main_pages.json
 D entry/src/main/resources/rawfile/actions/default_ai/* (5 个)
 D entry/src/main/resources/rawfile/vrm_samples/* (4 个)
D  entry/src/main/resources/rawfile/teacher-love.glb
D  entry/src/main/resources/rawfile/test_model.glb
D  entry/src/main/resources/rawfile/test_model_invalid.glb
D  full_hilog.txt / gen_glb.ps1 / hilog_*.txt / live_*.txt / loop_5times.ps1 / parse*.js / parse_layout.* / persist_hilog.txt / test_model.glb
D  snapshots/layout_action_mgr.json 等 3 个
D  test_models/** (22 个 GLB 文件)
 D tools/blender/generate_default_ai_actions.py
 D tools/model_converter_cli/main.cpp
 D tools/model_import_validation/* (2 个)
 D tools/parse_action_pack.js
 M TODO.md
 M AGENTS.md
?? docs/archive/3D_DISPLAY_FULL_AUDIT.md
?? docs/archive/CLEANUP_DRY_RUN.md
?? docs/archive/PHASE2_VRM_ONLY_REPORT.md
?? docs/archive/REMOVE_3D_DISPLAY_PLAN.md
?? docs/archive/T-3D.6E.md
?? docs/archive/T3D.6D.md
?? docs/archive/3d-action-research.md
```

完整 `git status --short` 原始输出已保留在 Git 工作区,可通过执行该命令实时查看。

---

## 十、精简删除清单

```text
- 删除页面         : 4   (AvatarLibraryPage / Character3DActionManagerPage / Character3DPocPage / HumanoidMappingPage)
- 删除组件         : 4   (ActionAvatarPreview3D / ActionPreviewCanvas / Character3DPanel / StableActionPreview3DHost)
- 删除 ViewModel   : 7   (含 Character3DPocViewModel 等)
- 删除 Service     : 20  (Character3DService / AvatarLibraryService / HumanoidRetargetor 等)
- 删除 Store       : 5   (AvatarLibraryStore / Model3DAssetStore / HumanoidMappingStore 等)
- 删除 Model       : 33  (character3d/* 与 vrm/* 子目录全部)
- 删除 Parser      : 22  (VRMImporter / Gltf* / Vrm* / ModelInspector 等)
- 删除 utils       : 4   (Chat3DDisplaySettings / QuaternionUtil / SceneNodeTransformUtil / ShaUtil)
- 删除测试         : 13  (VrmParserTest / GlbContainerAndSemanticTest / RetargetInvariantTest 等)
- 删除资源         : 47+ (VRM 样本 4 / GLB 模型 5 / 内置动作包 5 / test_models 22 / snapshots 3 / night_runs 5 / t4_2e_final 8 / phase2b dump 8)
- 删除 C++ Native  : 21  (model_converter/* / meshoptimizer_src/* / types/libmodel_converter/*)
- 删除工具脚本     : 5   (blender / model_converter_cli / model_import_validation / parse_action_pack)
- 删除路由         : 4
- 删除依赖         : 1   (libmodel_converter.so) + 1 个 externalNativeOptions 配置块
- 删除字符串资源   : 9   (settings_chat_3d_* / chat_3d_*)
- 删除临时文件     : 24+ (根目录 hilog_*.txt / parse*.js / *.ps1 等)
- 新增归档文档     : 7   (docs/archive/*)
- 修改文件         : 15
```

---

## 十一、任务边界声明

本任务只完成了:

```text
1. 完整删除现有 3D 展示及其相关系统
2. 确保角色卡、单人聊天、多人聊天正常
3. 生成报告
```

本任务未进行:

```text
- 重新实现 VRM
- 重新实现 3D Viewer
- 新增模型导入
- 新增动作系统
- 新增骨骼系统
- 重构角色卡
- 重构聊天系统
- 改变现有聊天 UI
- 改变角色卡业务规则
- 开发新的功能
```

后续是否重新开发 3D 能力,由用户检查并确认本报告后再行决定。

---

## 十二、构建与运行状态总览

```text
BUILD STATUS        : BUILD SUCCESSFUL in 31s 89ms (entry@default debug, 增量构建)
SIMULATOR STATUS    : HAP 安装成功,应用启动正常,无启动崩溃,无 3D Service 初始化错误
删除文件数量        : 217
修改文件数量        : 15
新增归档数量        : 7
删除代码行数        : 74231 deletions / 17 insertions
删除资源大小        : 约 21.6 MB
角色卡状态          : 正常(列表/创建/编辑/保存/头像/删除全部通过)
单人聊天状态        : 正常(进入/会话/历史/布局全部通过)
多人聊天状态        : 正常(列表/进入/成员/历史全部通过)
3D 残留扫描结果     : 生产 ArkTS 代码 0 命中,生产资源 0 命中,3D 路由 0 命中
报告路径            : D:\DevEco_studio\ArkTavern\REMOVE_3D_DISPLAY_REPORT.md
计划路径            : D:\DevEco_studio\ArkTavern\docs\archive\REMOVE_3D_DISPLAY_PLAN.md
```
