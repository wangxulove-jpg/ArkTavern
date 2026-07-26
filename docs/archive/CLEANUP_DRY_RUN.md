# ArkTavern VRM-only 收敛与项目清理 — Dry Run 盘点

## 0. 元数据

| 字段 | 值 |
|---|---|
| 报告类型 | 删除前盘点(Dry Run) |
| 生成时间 | 2026-07-26 (Asia/Shanghai) |
| 项目根目录 | `d:\DevEco_studio\ArkTavern` |
| 调查依据 | `3D_DISPLAY_FULL_AUDIT.md` |
| 目标格式策略 | Avatar: 仅 .vrm; 内置动作: 暂保留 .glb; 用户动作导入: 本轮关闭 |
| 删除原则 | 先盘点 → 确认引用 → 删除;仅删无引用或可再生产物 |
| Git 跟踪状态来源 | `git status --short` 与 `.gitignore` |

## 1. 候选文件总览

| 类别 | 文件数 | 总大小 | 处理策略 |
|---|---|---|---|
| 根目录诊断日志 | 9 | 333,757 B (326 KB) | 全部删除 + 更新 .gitignore |
| 根目录脚本 | 7 | 6,617 B (6.5 KB) | 全部删除 |
| 根目录截图 | 3 | 931,729 B (910 KB) | 全部删除 |
| `screenshots/` 目录 | 155 | 21,962,335 B (20.9 MB) | 整目录删除 + 已在 .gitignore |
| `snapshots/` 目录 | 4 | ~600 KB | 整目录删除 |
| `automation/` 目录 | 183 | 30,879,207 B (29.4 MB) | **部分保留**(`automation/ui/ark_tavern_ui_map.json` 必须保留) |
| `test_models/` 目录 | 22 | 19,517 B (19 KB) | 整目录删除 |
| `.hvigor/` 目录 | 209 | 40,214,438 B (38.4 MB) | 整目录删除(关闭 DevEco 后) |
| `.agent-cache/` 目录 | 112 | 11,117,878 B (10.6 MB) | 整目录删除 |
| `entry/build/` 目录 | 1040 | 219,361,031 B (209.2 MB) | 整目录删除(关闭 DevEco 后) |
| `entry/src/main/resources/rawfile/` 测试 GLB | 4 | 1,907,528 B (1.8 MB) | 删除 3 个 + 1 个待确认 |
| 旧格式兼容代码(8 模块) | 8 | ~50 KB | 停用入口 → 删除无引用代码 |
| 2D 预览硬编码(5 模块) | 5 | ~30 KB | 验证不参与真实播放后删除 |

**预计释放磁盘空间**:约 350 MB(不含 .vrm 样例与内置动作包)

---

## 2. 详细候选清单

### 2.1 根目录诊断日志(全部删除)

| 文件 | 大小 | Git 跟踪 | 全仓引用 | 建议动作 |
|---|---|---|---|---|
| `live_diag.txt` | 74,722 B | Untracked | 无 | 删除 |
| `diag_filter.txt` | 258,048 B | Untracked | 无 | 删除 |
| `live_hilog.txt` | 142 B | Untracked | 无 | 删除 |
| `app_hilog.txt` | 130 B | Untracked | 无 | 删除 |
| `hilog_snapshot.txt` | 39 B | Untracked | 无 | 删除 |
| `hilog_buffer.txt` | 39 B | Untracked | 无 | 删除 |
| `persist_hilog.txt` | 127 B | Untracked | 无 | 删除 |
| `full_hilog.txt` | 80 B | Untracked | 无 | 删除 |
| `diagnostic_hilog.txt` | 150 B | Untracked | 无 | 删除 |

**.gitignore 更新建议**(追加,不使用全局 `*.txt`):

```gitignore
/*hilog*.txt
/live_*.txt
/diag_*.txt
/diagnostic_*.txt
/screenshots/
/captures/
/ui_dumps/
*.trace
```

### 2.2 根目录脚本(全部删除)

| 文件 | 大小 | Git 跟踪 | 全仓引用 | 建议动作 |
|---|---|---|---|---|
| `parse_layout.ps1` | 1,068 B | Untracked | 无 | 删除 |
| `gen_glb.ps1` | 3,683 B | Untracked | 无 | 删除 |
| `loop_5times.ps1` | 1,540 B | Untracked | 无 | 删除 |
| `parse_layout.py` | 627 B | Untracked | 无 | 删除 |
| `parse-text3.js` | 618 B | Untracked | 无 | 删除 |
| `parse-id-text2.js` | 932 B | Untracked | 无 | 删除 |
| `parse-id-text.js` | 449 B | Untracked | 无 | 删除 |
| `parse-text.js` | 729 B | Untracked | 无 | 删除 |
| `parse-layout-3.js` | 763 B | Untracked | 无 | 删除 |
| `parse-layout-2.js` | 459 B | Untracked | 无 | 删除 |
| `parse-layout.js` | 670 B | Untracked | 无 | 删除 |

**.gitignore 更新建议**:

```gitignore
/parse_layout.ps1
/gen_glb.ps1
/loop_5times.ps1
/parse_layout.py
/parse-*.js
```

### 2.3 根目录截图(全部删除)

| 文件 | 大小 | Git 跟踪 | 全仓引用 | 建议动作 |
|---|---|---|---|---|
| `screen.png` | 423,472 B | 已在 .gitignore | 无 | 删除 |
| `screen-current.png` | 423,472 B | 已在 .gitignore | 无 | 删除 |
| `cur_screen.jpeg` | 84,785 B | 已在 .gitignore | 无 | 删除 |

### 2.4 `screenshots/` 目录(整目录删除)

- 文件数:155
- 总大小:21,962,335 B (20.9 MB)
- Git 跟踪:Untracked(已在 .gitignore)
- 内容:开发期 UI 截图、布局 JSON、分析脚本(Python)
- 全仓引用:无
- 建议动作:**整目录删除**

### 2.5 `snapshots/` 目录(整目录删除)

- 文件数:4
- 总大小:约 600 KB
- 内容:`v1_01_home.jpeg`、`v1_02_poc_fixed.jpeg`、`layout_action_mgr.json`、`layout_home.json`
- Git 跟踪:Untracked
- 全仓引用:无
- 建议动作:**整目录删除**

### 2.6 `automation/` 目录(部分保留)

- 文件数:183
- 总大小:30,879,207 B (29.4 MB)
- Git 跟踪:已在 .gitignore(但 `automation/ui/ark_tavern_ui_map.json` 在 `git status` 中显示为 modified,说明该文件被跟踪)

**保留清单**:

| 文件 | 跟踪状态 | 原因 |
|---|---|---|
| `automation/ui/ark_tavern_ui_map.json` | Modified(已跟踪) | 项目唯一正式 UI 自动化定位文件,AGENTS.md 强制保留 |

**删除清单**(其余 182 个文件全部删除):

| 子目录 | 文件类型 | 建议动作 |
|---|---|---|
| `automation/screenshots/` | UI 验收截图 | 删除 |
| `automation/ui/screenshots/` | UI 验收截图 | 删除 |
| `automation/ui/dump/` | UI 树 dump JSON | 删除 |
| `automation/ui/tmp/` | 临时截图与 dump | 删除 |
| `automation/ui/*.py` | 一次性分析脚本 | 删除 |
| `automation/ui/*.json` (除 ui_map) | 临时布局 JSON | 删除 |
| `automation/ui/*.txt` | hilog 临时文件 | 删除 |
| `automation/ui/*.png` | 临时截图 | 删除 |
| `automation/verification/` | 真机验收证据 | 删除(历史归档) |
| `automation/night_runs/` | 夜间运行记录 | 删除 |
| `automation/*.xml` | 旧 layout dump | 删除 |

### 2.7 `test_models/` 目录(整目录删除)

- 文件数:22
- 总大小:19,517 B (19 KB)
- Git 跟踪:已在 .gitignore
- 内容:GLB 容器边界测试 fixture(`01_all_zero_8bytes.glb` ~ `18_extremely_large_model.glb`、Box.glb 等样例)
- 全仓引用:无(代码不依赖此目录)
- 建议动作:**整目录删除**

### 2.8 `.hvigor/` 目录(整目录删除,需关闭 DevEco)

- 文件数:209
- 总大小:40,214,438 B (38.4 MB)
- Git 跟踪:已在 .gitignore
- 内容:构建日志、构建报告 JSON、缓存的 layout XML、临时截图
- 建议动作:**关闭 DevEco Studio 后整目录删除**

### 2.9 `.agent-cache/` 目录(整目录删除)

- 文件数:112
- 总大小:11,117,878 B (10.6 MB)
- Git 跟踪:已在 .gitignore
- 内容:AI Agent 开发期临时缓存(layout JSON、截图、PS1 脚本、character-actions 候选)
- 全仓引用:无
- 建议动作:**整目录删除**

### 2.10 `entry/build/` 目录(整目录删除,需关闭 DevEco)

- 文件数:1040
- 总大小:219,361,031 B (209.2 MB)
- Git 跟踪:已在 .gitignore
- 内容:HAP 包、ArkTS 编译缓存、原生库、资源拷贝
- 建议动作:**关闭 DevEco Studio 后整目录删除**(可再生)

### 2.11 `entry/src/main/resources/rawfile/` 测试 GLB

| 文件 | 大小 | Git 跟踪 | 引用位置 | 建议动作 |
|---|---|---|---|---|
| `default_ai_action_pack.glb` | 213,324 B | 已跟踪 | `BuiltInActionManifest.ets`、`Character3DActionService.ets` | **保留**(内置动作包) |
| `default_ai_action_pack.json` | 小 | 已跟踪 | `Character3DActionService.ets` | **保留**(内置动作元数据) |
| `preview_humanoid.glb` | 35,576 B | 已跟踪 | `BuiltInActionManifest.ets:74` (`BUILTIN_PREVIEW_FILE_NAME`)、`Character3DActionService.ets:553` | **待确认**(参见 2.11.1) |
| `teacher-love.glb` | 1,904,472 B | 已跟踪 | `Character3DPocPage.ets`、`Character3DPocViewModel.ets:1233-1235`(注释)、`Character3DService.ets:1090`(注释)、`SurfaceBonePickingService.ets:16`(注释) | **删除**(仅注释引用,无实际代码调用) |
| `test_model.glb` | 756 B | 已跟踪 | `Character3DService.ets:99` (`RAWFILE_TEST_MODEL_NAME`)、`:1079` (`importFromRawfile`) | **删除**(测试入口,VRM-only 后停用) |
| `test_model_invalid.glb` | 100 B | 已跟踪 | `TODO.md`、`3D_DISPLAY_FULL_AUDIT.md` (仅文档) | **删除**(负向 fixture,可改内存构造) |

**根目录 `test_model.glb`**(756 B,Untracked):删除(与 rawfile 重复)

#### 2.11.1 `preview_humanoid.glb` 引用详情

```
BuiltInActionManifest.ets:74: export const BUILTIN_PREVIEW_FILE_NAME = 'preview_humanoid.glb';
Character3DActionService.ets:553: return BUILTIN_ACTION_RAWFILE_DIR + '/' + BUILTIN_PREVIEW_FILE_NAME;
```

**调用链**:`Character3DActionService.ets:553` 在 `getBuiltinPreviewHumanoidUri()` 中返回路径,需进一步确认该方法是否仍被生产代码调用。Phase 1 阶段:`preview_humanoid.glb` 是动作预览的源骨架参考,**Phase 3 删除 2D 预览后**该文件可能成为孤儿。

**建议动作**:**Phase 3 删除**(随 2D 预览代码一并清理),Phase 1/2 保留。

### 2.12 VRM 样例资源(全部保留)

| 文件 | 大小 | 用途 |
|---|---|---|
| `entry/src/main/resources/rawfile/vrm_samples/vrm0_alicia_solid_0.51.vrm` | ~2 MB | VRM 0.x 样例 |
| `entry/src/main/resources/rawfile/vrm_samples/vrm1_constraint_twist.vrm` | ~1 MB | VRM 1.0 样例 |
| `entry/src/main/resources/rawfile/vrm_samples/vrm1_mtoon_uv_animation.vrm` | ~1 MB | VRM 1.0 样例 |
| `entry/src/main/resources/rawfile/vrm_samples/vrm1_seed_san.vrm` | ~2 MB | VRM 1.0 样例 |

**建议动作**:**全部保留**(VRM-only 策略的核心样例)

### 2.13 旧格式兼容代码候选

| 模块 | 文件 | 引用情况 | 建议动作 |
|---|---|---|---|
| `HumanoidMappingPage.ets` | `pages/HumanoidMappingPage.ets` | 注册于 `main_pages.json:28`;**无 router.pushUrl 调用**(仅 `AvatarLibraryPage.ets:17` 注释提及) | **Phase 3 删除** + 从 `main_pages.json` 移除 |
| `HumanoidMappingViewModel.ets` | `viewmodels/HumanoidMappingViewModel.ets` | 仅 `HumanoidMappingPage` 使用 | **Phase 3 删除** |
| `HumanoidMappingStore.ets` | `storage/HumanoidMappingStore.ets` | 仅 HumanoidMappingPage/ViewModel 使用 | **Phase 3 删除** |
| `SurfaceBonePickingService.ets` | `services/SurfaceBonePickingService.ets` | 仅 `HumanoidMappingViewModel.ets:57` + `SurfaceBonePickingTest.ets` 使用 | **Phase 3 删除** |
| `SurfaceBonePickingTest.ets` | `test/SurfaceBonePickingTest.ets` | 仅测试引用 SurfaceBonePickingService | **Phase 3 删除** |
| `SurfaceBoneCandidate.ets` | `models/character3d/SurfaceBoneCandidate.ets` | 全仓 Grep 无 import 引用 | **Phase 3 删除** |
| `BoneDebugOverlay.ets` | `models/character3d/BoneDebugOverlay.ets` | 全仓 Grep 无 import 引用 | **Phase 3 删除** |
| `ManualHumanoidMapping.ets` | `models/character3d/ManualHumanoidMapping.ets` | **被 VRM 代码引用**:`VrmHumanoidResolver.ets:15`、`HumanoidProvider.ets:23`、`AvatarAsset.ets:25`、`VrmHumanoidPipelineTest.ets:24` | **保留**(类型依赖,只删除 Manual Mapping UI 流程,不删类型定义) |

**Mixamo / 通用 GLB Avatar Profile**:全仓 Grep 无 `MixamoActionAvatarProfile` / `MixamoProfile` 匹配,**无需处理**(可能从未存在或已删除)。

### 2.14 2D 预览硬编码候选

| 模块 | 文件 | 引用情况 | 建议动作 |
|---|---|---|---|
| `ActionPreviewKeyframes.ets` | `models/character3d/ActionPreviewKeyframes.ets` | 仅 `Character3DActionPreviewRenderer.ets:24` 引用 | **Phase 3 删除** |
| `DefaultHumanoidSkeleton.ets` | `models/character3d/DefaultHumanoidSkeleton.ets` | 仅 `ActionPreviewKeyframes.ets:20` 引用 | **Phase 3 删除** |
| `Character3DActionPreviewRenderer.ets` | `models/character3d/Character3DActionPreviewRenderer.ets` | 全仓无生产代码 import | **Phase 3 删除** |
| `ActionPreviewCanvas.ets` | `components/ActionPreviewCanvas.ets` | `Character3DActionManagerPage.ets:73` 引用(用于 `SkeletonDisplayMode.SourceActionPreview` 模式) | **Phase 3 删除**(同时移除 import 与 SourceActionPreview 模式分支) |
| `SkeletonDisplayMode.SourceActionPreview` | `models/character3d/SkeletonDisplayMode.ets` | `Character3DActionManagerPage.ets:453` 使用 | **Phase 3 删除枚举值** |

**验证条件**:确认这些 2D 预览代码不参与真实 3D 动作播放。根据 `3D_DISPLAY_FULL_AUDIT.md` 第 9.3 节:
- `SourceActionPreview` 模式仅在 UI 上隐藏 Component3D,显示 ActionPreviewCanvas
- 不参与 Retarget 数学计算
- 不写入 Target Skeleton
- 仅作为"源骨架示意",**不影响真实动作播放**

### 2.15 3D Host 候选(Phase 6 处理)

| 组件 | 文件 | 状态 | 引用情况 |
|---|---|---|---|
| 页面直接 `Component3D` | `Character3DActionManagerPage.ets:1474-1477` | **生产路径** | `if (this.actionDialogScene !== null) Component3D(...)` |
| `StableActionPreview3DHost` | `components/StableActionPreview3DHost.ets` | **已定义未使用** | `Character3DActionManagerPage.ets:75` import 但 buildActionDialog 未调用 |
| `ActionAvatarPreview3D` | `components/ActionAvatarPreview3D.ets` | **已定义未使用** | `Character3DActionManagerPage.ets:74` import 但 buildActionDialog 未调用 |

**Phase 6 处理策略**:
1. 先输出三个组件的调用图与引用计数
2. 推荐最终保留 `StableActionPreview3DHost`(重命名为 `ActionPreview3DHost`,或保留现名)
3. 真机验证通过后删除 `ActionAvatarPreview3D.ets` + 移除 `Character3DActionManagerPage` 中的直接 `Component3D` 渲染 + 移除无效计数器 `hostCreatedCount` / `hostDisposedCount`

---

## 3. 不可删除清单(强制保留)

### 3.1 内置动作包

```
entry/src/main/resources/rawfile/actions/default_ai/default_ai_action_pack.glb
entry/src/main/resources/rawfile/actions/default_ai/default_ai_action_pack.json
entry/src/main/resources/rawfile/actions/default_ai/SOURCE.txt
entry/src/main/resources/rawfile/actions/default_ai/LICENSE.txt
```

### 3.2 GLB 容器解析基础设施(VRM 仍依赖)

```
entry/src/main/ets/parser/GltfAnimationParser.ets
entry/src/main/ets/parser/GltfAnimationDataParser.ets
entry/src/main/ets/parser/GltfVertexAccessor.ets
entry/src/main/ets/parser/GltfSemanticValidator.ets
entry/src/main/ets/parser/GltfSkinMaterialAnalyzer.ets
entry/src/main/ets/parser/GltfValidator.ets
entry/src/main/ets/parser/ModelInspector.ets
```

### 3.3 VRM 解析器(强制保留)

```
entry/src/main/ets/parser/VRMImporter.ets
entry/src/main/ets/parser/VrmHumanoidMapper.ets
entry/src/main/ets/parser/VrmHumanoidResolver.ets
entry/src/main/ets/parser/VrmBoneKeyParser.ets
entry/src/main/ets/parser/VrmExtensionParser.ets
entry/src/main/ets/parser/VrmDetector.ets
entry/src/main/ets/models/character3d/vrm/VrmAsset.ets
```

### 3.4 类型定义(被 VRM 代码依赖)

```
entry/src/main/ets/models/character3d/ManualHumanoidMapping.ets  # 类型依赖,不删
```

### 3.5 UI 自动化资产(强制保留)

```
automation/ui/ark_tavern_ui_map.json  # 项目唯一正式 UI 自动化定位文件
```

### 3.6 用户已有未提交修改(强制保留)

调查开始前已有的 13 个 Modified + 22 个 Untracked 文件,详见 `3D_DISPLAY_FULL_AUDIT.md` 附录 D。

---

## 4. 删除阶段拆分

### Phase 1: cleanup generated files(清理生成产物)

**删除范围**:
- 9 个根目录诊断日志
- 11 个根目录脚本
- 3 个根目录截图
- `screenshots/` 整目录
- `snapshots/` 整目录
- `automation/` 整目录(保留 `automation/ui/ark_tavern_ui_map.json`)
- `test_models/` 整目录
- `.agent-cache/` 整目录
- `.hvigor/` 整目录(**需确认 DevEco Studio 已关闭**)
- `entry/build/` 整目录(**需确认 DevEco Studio 已关闭**)
- `entry/src/main/resources/rawfile/teacher-love.glb`
- `entry/src/main/resources/rawfile/test_model.glb`
- `entry/src/main/resources/rawfile/test_model_invalid.glb`
- 根目录 `test_model.glb`

**修改文件**:
- `.gitignore`:追加 hilog/log/screen/脚本忽略规则
- `entry/src/main/ets/services/Character3DService.ets`:移除 `RAWFILE_TEST_MODEL_NAME` 常量与 `importFromRawfile()` 方法
- `entry/src/main/ets/viewmodels/Character3DPocViewModel.ets`:移除 `importFromRawfileByName` 中 `teacher-love.glb` 注释
- `entry/src/main/ets/pages/Character3DPocPage.ets`:移除 `test_model.glb` 注释

**风险**:
- `test_model.glb` 删除后,`Character3DService.importFromRawfile()` 调用会失败 → 需先停用调用入口
- 验证 `importFromRawfile` 是否仍被生产代码调用,若已被 AvatarLibraryService 替代则可安全删除

### Phase 2: enforce VRM-only avatar import(VRM-only 强制)

**修改范围**:
- `AvatarLibraryPage.ets`:文件选择器只接受 `.vrm`
- `AvatarLibraryService.ets`:`importFromUri` 拒绝非 VRM 文件
- `Character3DService.ets`:`importFromRawfileByName` 增加 VRM 扩展校验
  - 必须存在 VRM 0.x `VRM` 扩展或 VRM 1.0 `VRMC_vrm` 扩展
  - 必须存在有效 Humanoid
  - 必需骨骼缺失则拒绝导入
- 删除普通 GLB/GLTF Avatar 导入分支
- 错误提示:".glb/.gltf 不再支持,请转换为 VRM"

**新增/修改测试**:
- VRM-only 校验测试:非 VRM 文件被拒绝
- VRM 0.x / 1.0 双格式接受测试

### Phase 3: remove legacy mapping and 2D preview(删除旧映射与 2D 预览)

**删除文件**:
- `pages/HumanoidMappingPage.ets`
- `viewmodels/HumanoidMappingViewModel.ets`
- `storage/HumanoidMappingStore.ets`
- `services/SurfaceBonePickingService.ets`
- `test/SurfaceBonePickingTest.ets`
- `models/character3d/SurfaceBoneCandidate.ets`
- `models/character3d/BoneDebugOverlay.ets`
- `models/character3d/ActionPreviewKeyframes.ets`
- `models/character3d/DefaultHumanoidSkeleton.ets`
- `models/character3d/Character3DActionPreviewRenderer.ets`
- `components/ActionPreviewCanvas.ets`
- `entry/src/main/resources/rawfile/actions/default_ai/preview_humanoid.glb`(若 Phase 3 后无引用)

**修改文件**:
- `entry/src/main/resources/base/profile/main_pages.json`:移除 `pages/HumanoidMappingPage`
- `pages/Character3DActionManagerPage.ets`:移除 `ActionPreviewCanvas` import + `SourceActionPreview` 模式分支 + "配置骨骼"按钮(若指向 HumanoidMappingPage)
- `pages/AvatarLibraryPage.ets`:移除 HumanoidMappingPage 注释
- `models/character3d/SkeletonDisplayMode.ets`:移除 `SourceActionPreview` 枚举值 + `shouldUseSourceActionPreview` 函数
- `models/character3d/BuiltInActionManifest.ets`:移除 `BUILTIN_PREVIEW_FILE_NAME` 常量(若 preview_humanoid.glb 已删)
- `services/Character3DActionService.ets`:移除 `getBuiltinPreviewHumanoidUri()` 方法(若已无引用)

**保留**:
- `models/character3d/ManualHumanoidMapping.ets`(类型定义被 VRM 代码依赖)
- `test/HumanoidMappingTest.ets`(若仍测试 ManualHumanoidMapping 类型,保留)

**显示模式收敛为**:
- `ModelOnly`(仅模型)
- `ModelWithSkeleton`(模型 + 骨架)
- `SkeletonOnly`(仅骨架)

### Phase 4: isolate debug diagnostics(诊断代码隔离)

**修改范围**:
- 引入 `BuildProfile.isDebugMode` 或现有 `IS_DEV_BUILD` 常量(扩展到全局)
- `services/SourceRetargetDiagnosticCollector.ets`:
  - `collectFullDiagnosticSnapshot` / `runFullBasisAndAxisDiagnostic` 在 Release 中跳过
- `services/SourceTargetCompareSkeleton.ets`:
  - `attach` / `updateFrame` 在 Release 中直接返回
- `services/TargetAvatarSkeletonController.ets`:
  - `setDebugMode(false)` 在 Release 中强制
  - 红绿点诊断 Geometry 不创建
- `services/HumanoidRetargetPlaybackController.ets`:
  - `logSummary` / `maybeLogSegment` 在 Release 中跳过
  - `firstFrameDelta` 诊断快照在 Release 中跳过

**约束**:
- Release 不创建 Debug Geometry
- Release 不执行诊断快照
- Release 不重复执行 retarget
- Release 不展示 Debug 控件

### Phase 5: optimize memory and frame performance(性能优化)

**A. 日志不重复计算**:
- `services/HumanoidRetargetPlaybackController.ets`:
  - `applyFrame` 缓存 `lastSampledPose` / `lastRetargetResult`
  - `logSummary` / `maybeLogSegment` 读取缓存,**不再调用 `sampleMotionClip` / `retargetPose`**

**B. World Transform 帧缓存**:
- `services/TargetAvatarSkeletonController.ets`:
  - `updateFrame()` 内创建 `Map<Node, WorldTransform>` 每帧缓存
  - 父节点结果同一帧复用
  - 帧结束清空
  - 暂不实现长期 dirty cache

**C. Buffer 生命周期**:
- `viewmodels/ActionAvatarPreviewViewModel.ets`:
  - Avatar Buffer 完成解析和映射后立即置 null
  - 动作包 Buffer 全局只保留一份(`actionPackBuffer` 单例)
  - 切换动作不重复读取同一动作包
  - 关闭详情窗口清除 Clip 和诊断快照

### Phase 6: consolidate Component3D host(3D Host 收敛)

**步骤**:
1. 输出三组件调用图与引用计数(本次 Dry Run 已完成,见 2.15)
2. 修改 `Character3DActionManagerPage.ets` `buildActionDialog()`:
   - 移除直接 `Component3D` 渲染
   - 改用 `StableActionPreview3DHost` 包装
   - 移除 `if (this.actionDialogScene !== null)` 包裹
3. 真机验证:
   - 连续打开动作详情 10 次,无黑屏/闪烁
   - Surface 创建计数应为 1
4. 验证通过后删除:
   - `components/ActionAvatarPreview3D.ets`
   - `Character3DActionManagerPage.ets` 中的 `hostCreatedCount` / `hostDisposedCount` 计数器(若 StableActionPreview3DHost 自身已具备等价诊断)

---

## 5. 引用确认矩阵

### 5.1 `test_model.glb` / `importFromRawfile` 调用链

```
Character3DService.ets:99     const RAWFILE_TEST_MODEL_NAME = 'test_model.glb'
Character3DService.ets:1079   importFromRawfile() → 调用 importFromRawfileByName(RAWFILE_TEST_MODEL_NAME, ...)
Character3DService.ets:1095   importFromRawfileByName(fileName, displayName, keepOldModel=false)
```

**调用方**:`importFromRawfile()` 是否仍被生产代码调用?需进一步确认。
**AvatarLibraryService** 已使用 `importFromRawfileByName(fileName, displayName, keepOldModel=true)` 处理 VRM,因此 `importFromRawfile()`(无参版)若仅被 PoC 测试入口调用,可安全删除。

### 5.2 `teacher-love.glb` 引用确认

```
Character3DPocPage.ets:1354        // 注释:test_model.glb rawfile 保留用于自动测试
Character3DPocViewModel.ets:1233    // 注释:模拟器无 Download 目录,改用 rawfile 方式加载 teacher-love.glb
Character3DPocViewModel.ets:1235    // 注释:rawfile 中的文件名(如 'teacher-love.glb')
Character3DService.ets:1090         // 注释:rawfile 中的文件名(如 'teacher-love.glb')
SurfaceBonePickingService.ets:16    // 注释:teacher-love 约 1k 三角形可接受
```

**结论**:仅注释引用,**无实际代码调用 `teacher-love.glb`**,可安全删除。
**附带修改**:更新上述注释或删除相关注释行。

### 5.3 `preview_humanoid.glb` 调用链

```
BuiltInActionManifest.ets:74    export const BUILTIN_PREVIEW_FILE_NAME = 'preview_humanoid.glb'
Character3DActionService.ets:72 import { BUILTIN_PREVIEW_FILE_NAME }
Character3DActionService.ets:553 return BUILTIN_ACTION_RAWFILE_DIR + '/' + BUILTIN_PREVIEW_FILE_NAME
```

**调用方**:`Character3DActionService.ets:553` 的方法名(待 Read 确认),需检查该方法是否被 AvatarLibraryService 或 ActionAvatarPreviewViewModel 调用。
**建议**:Phase 3 删除 2D 预览时一并清理,若仍有生产引用则保留。

### 5.4 `HumanoidMappingPage` 路由调用

```
main_pages.json:28              "pages/HumanoidMappingPage"
AvatarLibraryPage.ets:17        // 注释:骨骼映射编辑(由 HumanoidMappingPage 负责)
TODO.md:7851                    注释:Character3DActionManagerPage "配置骨骼"按钮的 onClick 仅调用 router.pushUrl({ url: 'pages/HumanoidMappingPage' })
```

**Grep 结果**:全仓**无 `router.pushUrl({ url: 'pages/HumanoidMappingPage' })` 实际调用**(仅 TODO.md 提及历史设计)。
**结论**:`HumanoidMappingPage` 已是孤儿页面,可安全删除。

### 5.5 `ManualHumanoidMapping` 类型依赖(VRM 代码)

```
parser/VrmHumanoidResolver.ets:15    import { HumanoidJointBinding, BoneMappingMethod } from '../models/character3d/ManualHumanoidMapping'
services/HumanoidProvider.ets:23     import { ManualHumanoidMapping, HumanoidJointBinding, BoneMappingMethod } from '../models/character3d/ManualHumanoidMapping'
models/character3d/AvatarAsset.ets:25 import { ManualHumanoidMapping } from './ManualHumanoidMapping'
test/VrmHumanoidPipelineTest.ets:24  import { BoneMappingMethod } from '../models/character3d/ManualHumanoidMapping'
```

**结论**:`ManualHumanoidMapping.ets` 提供的类型(`HumanoidJointBinding`、`BoneMappingMethod`、`ManualHumanoidMapping`)被 VRM 解析器、Provider、AvatarAsset、VRM 测试依赖。
**建议**:**保留该文件**,只删除 Manual Mapping 的 UI 流程(HumanoidMappingPage / HumanoidMappingViewModel / HumanoidMappingStore)。

---

## 6. 风险评估

| 风险 | 影响 | 缓解措施 |
|---|---|---|
| DevEco Studio 运行时删除 `entry/build/` | 构建失败、IDE 状态异常 | 删除前确认 DevEco 已关闭;`tasklist` 检查 devenv.exe / hvigor.exe 进程 |
| 删除 `test_model.glb` 后 `importFromRawfile()` 调用失败 | 运行时异常 | Phase 1 同步移除 `importFromRawfile()` 方法及其调用入口 |
| 删除 `HumanoidMappingPage` 后 `main_pages.json` 残留 | 编译失败 | 同步更新 `main_pages.json` |
| 删除 `ActionPreviewCanvas` 后 `Character3DActionManagerPage` 残留 import | 编译失败 | 同步移除 import 与 SourceActionPreview 模式分支 |
| `ManualHumanoidMapping.ets` 误删 | VRM 解析器编译失败 | **强制保留**(类型依赖) |
| 删除 `preview_humanoid.glb` 后 `BUILTIN_PREVIEW_FILE_NAME` 残留 | 编译失败 | 同步移除常量与 `getBuiltinPreviewHumanoidUri` 方法 |
| 真机黑屏/闪烁复发 | 用户体验下降 | Phase 6 真机验证通过后才删除 `ActionAvatarPreview3D` |

---

## 7. 提交拆分(6 阶段)

| 阶段 | 主题 | 修改文件数 | 删除文件数 | 验证 |
|---|---|---|---|---|
| Phase 1 | cleanup generated files | ~5 | ~1700+(批量) | `git status --short` 仅剩预期变化;DevEco 启动正常 |
| Phase 2 | enforce VRM-only avatar import | ~3 | 0 | VRM 0.x / 1.0 样例可导入;非 VRM 被拒绝 |
| Phase 3 | remove legacy mapping and 2D preview | ~5 | ~11 | 增量编译通过;动作详情窗口正常;`SourceActionPreview` 模式消失 |
| Phase 4 | isolate debug diagnostics | ~4 | 0 | Release 不创建 Debug Geometry;Debug 模式诊断正常 |
| Phase 5 | optimize memory and frame performance | ~2 | 0 | 日志 retarget 次数下降;World Transform 计算次数下降 |
| Phase 6 | consolidate Component3D host | ~2 | 1(ActionAvatarPreview3D) | 连续打开动作详情 10 次无黑屏 |

每阶段失败立即停止,不继续下一阶段。

---

## 8. 待确认事项(需用户决策)

### 8.1 DevEco Studio 状态

Phase 1 删除 `entry/build/` 与 `.hvigor/` 前,需确认 DevEco Studio 已关闭。
**问题**:用户当前是否已关闭 DevEco Studio?

### 8.2 `preview_humanoid.glb` 处理时机

**选项 A**(推荐):Phase 3 删除(随 2D 预览代码一并清理)
**选项 B**:Phase 1 删除(若确认 `getBuiltinPreviewHumanoidUri` 无生产引用)
**选项 C**:保留(若计划未来恢复 2D 预览)

### 8.3 `ManualHumanoidMapping.ets` 处理

**选项 A**(推荐):保留(类型依赖)
**选项 B**:重构 — 将 `HumanoidJointBinding`、`BoneMappingMethod` 迁移到 `HumanoidBone.ets`,然后删除 `ManualHumanoidMapping.ets`(超出本轮范围)

### 8.4 `test/HumanoidMappingTest.ets` 处理

需进一步确认该测试是否测试 `ManualHumanoidMapping` 类型(保留)还是 Manual Mapping UI 流程(删除)。

### 8.5 `IS_DEV_BUILD` 全局化

Phase 4 需要将 `Character3DActionManagerPage.ets:102` 的 `IS_DEV_BUILD` 常量提升到全局(如 `BuildProfile.ets` 或 `AppServices.ets`),供其他模块共享。
**问题**:是否同意新增全局 `IS_DEV_BUILD` 常量?

---

## 9. Dry Run 结论

本次 Dry Run 完成全部候选文件盘点:

1. **总候选文件数**:约 1750+(含 `entry/build/` 1040 个)
2. **预计释放空间**:约 350 MB
3. **强制保留**:`default_ai_action_pack.glb`、VRM 样例、GLB 解析基础设施、VRM 解析器、`ManualHumanoidMapping.ets` 类型定义、`automation/ui/ark_tavern_ui_map.json`
4. **高风险操作**:删除 `entry/build/` 与 `.hvigor/`(需关闭 DevEco)、删除 `test_model.glb`(需同步移除 `importFromRawfile`)
5. **待用户决策**:5 项(见第 8 节)

**等待用户确认后进入 Phase 1 执行**。

---

**Dry Run 结束**
