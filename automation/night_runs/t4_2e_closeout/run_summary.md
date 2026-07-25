# T-4.2E-Closeout 夜间自主收尾报告

**任务**: VRM 动作重定向收尾、数据一致性修复与夜间自主实机验收
**执行时间**: 2026-07-25 00:35 ~ 02:40 (含前置 T-4.2E MVP)
**最终验收时间**: 2026-07-25 02:30 ~ 02:40
**设备**: 127.0.0.1:5555 (nova 13 Pro, HarmonyOS NEXT)

---

## 1. 修改文件清单

### T-4.2E MVP 阶段(2026-07-24)
- `entry/src/main/ets/parser/GltfAnimationDataParser.ets` (新增)
- `entry/src/main/ets/models/character3d/HumanoidMotionClip.ets` (新增)
- `entry/src/main/ets/services/HumanoidMotionSampler.ets` (新增)
- `entry/src/main/ets/services/HumanoidRetargetor.ets` (新增)
- `entry/src/main/ets/services/HumanoidRetargetPlaybackController.ets` (新增)
- `entry/src/main/ets/services/SceneNodeCollector.ets` (新增)
- `entry/src/main/ets/services/TargetRestPoseCollector.ets` (新增)
- `entry/src/main/ets/utils/QuaternionUtil.ets` (新增)
- `entry/src/main/ets/viewmodels/ActionAvatarPreviewViewModel.ets` (修改)
- `entry/src/main/ets/pages/Character3DActionManagerPage.ets` (修改)

### T-4.2E-Closeout 收尾阶段(2026-07-25)
- `entry/src/main/ets/utils/ShaUtil.ets` (新增) - SHA-256 计算工具
- `entry/src/main/ets/services/Character3DService.ets` (修改) - importFromRawfileByName 计算 SHA
- `entry/src/main/ets/services/AvatarLibraryService.ets` (修改) - 新增 repairEmptySha256 方法
- `entry/src/main/ets/services/AppServices.ets` (修改) - 启动时自动修复空 SHA
- `entry/src/main/ets/database/DbHelper.ets` (修改) - ensureSchemaExists 改为幂等
- `entry/src/main/ets/services/HumanoidRetargetPlaybackController.ets` (修改) - Stopped 状态 play() 重置 currentTime
- `entry/src/main/ets/viewmodels/ActionAvatarPreviewViewModel.ets` (修改) - 删除单骨骼测试方法
- `entry/src/main/ets/pages/Character3DActionManagerPage.ets` (修改) - 删除单骨骼测试按钮
- `entry/src/main/ets/pages/Character3DPocPage.ets` (修改) - 临时导入按钮(开发自测用,任务完成后保留以支持后续 VRM 样本导入)
- `TODO.md` (修改) - T-4.2E + T-4.2E-Closeout 完整记录

---

## 2-6. AT_Wave 动作索引与解析事实

| 字段 | 值 |
|------|-----|
| **AT_Wave manifestClipIndex** | **5** |
| **AT_Wave gltfAnimationIndex** | **14** |
| **duration** | 2.000s |
| **channels** | 66 |
| **samplers** | 66 |
| **tracks** | 22 (rotationTracks=22, translationTracks=22) |
| **interpolation** | **STEP** (全部) |

**关键修正**: 历史报告错误将 AT_Wave manifest clipIndex 写为 0(实际为 5),并错误标注插值为 LINEAR(实际为 STEP)。GLB animation index 与 manifest clipIndex 是两个独立概念,运行时按 clipName 查找,不依赖任一 index。

---

## 7-9. 骨骼映射数据

| 字段 | 值 |
|------|-----|
| **source Humanoid 数** | 22 (来自 GLB 动作包) |
| **target Humanoid 数** | 21 (VRM 1.0 显式骨骼) |
| **mapped bone 数** | 21 |
| **appliedBones** | 21 (每帧) |
| **changedBones** | AT_Wave=3, AT_Thinking=4, AT_Idle=4 |

---

## 10-11. 四元数与 Root Motion

- **quaternion 乘法顺序**: `sourceDelta = inverse(sourceRest) × sourceAnimated`; `targetAnimated = targetRest × sourceDelta`
- **RootMotionMode**: `HipsOnly` (仅旋转,不应用位移)
- **不变量验证**: source==rest 时 target==rest(单元测试覆盖)

---

## 12. sourceSha256 修复与迁移结果

### 原问题
- `importFromRawfileByName` 硬编码 `sourceSha256: ''`
- 旧 AvatarRecord.sourceSha256 为空,影响 VRM asset cache / humanoid mapping cache / duplicate detection

### 修复方式
1. 新增 `utils/ShaUtil.ets` 提供 `computeSha256Base64(buffer)` 统一工具
2. `Character3DService.importFromRawfileByName` 读取 rawfile 后计算 SHA-256
3. `AvatarLibraryService.repairEmptySha256()` 扫描所有空 SHA 记录,读取模型文件重新计算并更新
4. `AppServices` 启动时异步调用 `repairEmptySha256()`(不阻塞启动)
5. `DbHelper.ensureSchemaExists` 改为仅执行 CREATE TABLE/INDEX IF NOT EXISTS(修复 code=14800021)

### 迁移结果(实机验证)
```
AvatarLibraryService | repairEmptySha256: start, scanned=1
AvatarLibraryService | repairEmptySha256: done, scanned=1, empty=0, repaired=0, missing=0, failed=0
```
- 首次修复后所有记录 SHA 非空
- 重启应用后 `empty=0`,证明持久化成功
- active Avatar 未变化(displayName/tags/favorite 保留)

### 回退解析策略
- `ActionAvatarPreviewViewModel.parseVrmFromGlbBuffer`: 直接从 GLB buffer 解析 VRM
- 作为缓存缺失/损坏/parserVersion 变化/SHA 迁移前的回退路径
- 正常路径不长期依赖空 SHA

---

## 13. 临时测试按钮删除结果

- `Character3DActionManagerPage.ets`: 删除"测试骨骼旋转(5s)"按钮及"停止测试"按钮
- `ActionAvatarPreviewViewModel.ets`: 删除 `runSingleBoneTest`/`stopSingleBoneTest` 方法及相关成员变量
- 正式 release/default HAP 中无单骨骼调试入口
- UI map 中未记录该按钮,无需同步更新

---

## 14-17. AT_Wave 三时间点视觉验收

| 采样点 | currentTime | 截图哈希(SHA256 前 8 位) |
|--------|-------------|--------------------------|
| **wave_t0.png** | 0.000~0.15s | F1D9C758 |
| **wave_t05.png** | 0.40~0.65s | 2CD91D0A |
| **wave_t10.png** | 0.90~1.15s | 8BD592C2 |

**视觉差异**: 三张图哈希完全不同,肉眼可见右肩/右上臂/右前臂/右手姿态随时间明显变化。t0 为初始抬起,t05 为手臂继续上抬,t10 为挥手动作中段。

---

## 18-20. 播放控制验收

### Pause
- 在 currentTime=0.838 时点击暂停
- 2s 后姿态保持(哈希 153A3B97)
- 按钮文案变为"播放"
- 日志: `Retarget pause: clip=AT_Wave, currentTime=0.838`

### Replay
- 点击重播后 currentTime 返回 0
- 动作重新开始,手臂从初始姿态进入挥手
- 日志: `Retarget replay: clip=AT_Wave`

### Stop & Rest Pose
- 点击停止后 timer 取消,currentTime=0
- Rest Pose 恢复(哈希 0C856D0A)
- 右臂回到初始姿态
- 再次播放仍正常
- 日志: `Retarget stop: rest pose restored` + `restoreTargetRestPose: restored=21`

---

## 21. AT_Thinking 验收

| 字段 | 值 |
|------|-----|
| manifestClipIndex | 2 |
| gltfAnimationIndex | 12 |
| duration | 3.000s |
| loop | true |
| tracks | 22 |
| appliedBoneCount | 21 |
| changedBoneCount | 4 |

- 连续播放 47s,跨 15 次循环
- changedBones=4 持续变化(头部/颈部/脊柱/手臂)
- 循环边界无明显姿态跳变
- 关闭后 Rest Pose 恢复(restored=21)
- 播放/停止截图哈希不同(8C1C2DA8 vs 3B13D8CB)

---

## 22. AT_Idle 循环验收

| 字段 | 值 |
|------|-----|
| manifestClipIndex | 0 |
| gltfAnimationIndex | 6 |
| duration | 4.000s |
| loop | true |
| tracks | 22 |
| appliedBoneCount | 21 |
| changedBoneCount | 4 |

- 连续播放 101s,跨 ~25 次循环
- 模型保持微动作,不静止
- 循环边界无明显姿态跳变
- 不出现逐循环旋转累积
- 不出现人物持续偏移
- Hips 位移不漂移
- 两张循环截图哈希不同(7D911532 vs C0C195A4)
- 关闭后 Rest Pose 恢复(restored=21)

---

## 23. 单元测试

- GltfAnimationDataParserTest: 通过(覆盖 AT_Wave 解析、LINEAR/STEP、accessor 验证、未知 animation name、duration、trackCount)
- HumanoidMotionSamplerTest: 通过(覆盖 0/1/多关键帧、slerp、shortest path、STEP、loop、clamp、非法 quaternion)
- HumanoidRetargetorTest: 通过(覆盖 source→target delta、左右不串位、缺失骨骼跳过、stop 恢复 rest、quaternion 顺序不变量)
- AvatarLibraryShaMigrationTest: 通过(覆盖空 SHA 修复、非空不重复计算、文件缺失不伪造、active 不变、重启持久化)

---

## 24-25. 构建结果

- **BUILD SUCCESSFUL** in 16s 963ms
- **HAP 路径**: `entry/build/default/outputs/default/entry-default-signed.hap`
- 覆盖安装成功,保留应用数据

---

## 26-29. 设备与产物路径

- **设备**: 127.0.0.1:5555 (nova 13 Pro, HarmonyOS NEXT)
- **hilog 路径**: `automation/night_runs/t4_2e_closeout/hilog_final.txt` / `hilog_filtered.txt`
- **最终截图路径**: `automation/screenshots/t4_2e_final/`
  - wave_t0.png / wave_t05.png / wave_t10.png
  - wave_paused.png / wave_replay.png / wave_stopped.png
  - thinking.jpeg
  - idle_cycle_1.jpeg / idle_cycle_2.jpeg
  - final_action_dialog.jpeg
- **TODO.md 行号**: 5946-6106 (T-4.2E + T-4.2E-Closeout 章节)

---

## 30. 尚未实现的明确限制

- 无 IK / Foot IK
- 无手指精细动作
- 无动画混合 / CrossFade
- 无动作编辑器 / 时间轴
- 无 Expression Runtime
- 无 LookAt Runtime
- 无 SpringBone 与动作联动
- 无聊天动作联动
- 无新模型格式支持(仅 VRM/GLB)
- Hips 位移策略:HipsOnly(仅旋转,不应用位移)
- CUBICSPLINE 插值未实现(检测并返回 UnsupportedInterpolation)

---

## 最终完成条件核对

| # | 条件 | 状态 |
|---|------|------|
| 1 | AT_Wave manifestClipIndex=5 | ✅ |
| 2 | GLB animation index 已独立记录(=14) | ✅ |
| 3 | sourceSha256 不再为空 | ✅ |
| 4 | 旧空 SHA Avatar 已迁移或明确标记失败 | ✅ |
| 5 | 正式 UI 中无"测试骨骼旋转(5s)"按钮 | ✅ |
| 6 | AT_Wave 三张截图姿态明显不同 | ✅ |
| 7 | 暂停后姿态保持 | ✅ |
| 8 | 重播从头开始 | ✅ |
| 9 | 停止后恢复 Rest Pose | ✅ |
| 10 | AT_Thinking 肉眼可见动作 | ✅ |
| 11 | AT_Idle 跨循环无明显漂移 | ✅ |
| 12 | 切换动作不串状态 | ✅ |
| 13 | 关闭弹窗不泄漏 timer | ✅ |
| 14 | 切换 Avatar 不复用旧 bone node map | ✅ |
| 15 | 单元测试通过 | ✅ |
| 16 | BUILD SUCCESSFUL | ✅ |
| 17 | HAP 安装成功 | ✅ |
| 18 | hilog 无严重错误 | ✅ |
| 19 | 临时文件已清理 | ✅ |
| 20 | TODO.md 已更新 | ✅ |

**全部 20 项完成条件满足。任务完成。**

按任务要求停止,不自动进入 IK、动作混合、手指、Expression、SpringBone 或聊天动作联动。
