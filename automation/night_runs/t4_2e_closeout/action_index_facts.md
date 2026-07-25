# T-4.2E Closeout - 动作索引事实确认

## 数据来源
- Manifest: `entry/src/main/resources/rawfile/actions/default_ai/default_ai_action_pack.json`
- GLB: `entry/src/main/resources/rawfile/actions/default_ai/default_ai_action_pack.glb`
- 解析工具: `automation/tmp/inspect_action_pack.js` (临时,任务结束删除)

## GLB animations[] 实际顺序(按字母序)

| gltfIndex | name | duration | channels | rot | trans | scale | interp |
|-----------|------|----------|----------|-----|-------|-------|--------|
| 0 | AT_Angry | 1.792s | 66 | 22 | 22 | 22 | STEP |
| 1 | AT_Apology | 1.500s | 66 | 22 | 22 | 22 | STEP |
| 2 | AT_Celebrate | 2.167s | 66 | 22 | 22 | 22 | STEP |
| 3 | AT_Confused | 2.000s | 66 | 22 | 22 | 22 | STEP |
| 4 | AT_Greeting | 1.792s | 66 | 22 | 22 | 22 | STEP |
| 5 | AT_Happy | 1.792s | 66 | 22 | 22 | 22 | STEP |
| 6 | AT_Idle | 4.000s | 66 | 22 | 22 | 22 | STEP |
| 7 | AT_Listening | 3.000s | 66 | 22 | 22 | 22 | STEP |
| 8 | AT_Nod | 1.167s | 66 | 22 | 22 | 22 | STEP |
| 9 | AT_Sad | 2.000s | 66 | 22 | 22 | 22 | STEP |
| 10 | AT_ShakeHead | 1.167s | 66 | 22 | 22 | 22 | STEP |
| 11 | AT_Speaking | 2.000s | 66 | 22 | 22 | 22 | STEP |
| 12 | AT_Thinking | 3.000s | 66 | 22 | 22 | 22 | STEP |
| 13 | AT_TouchReaction | 0.792s | 66 | 22 | 22 | 22 | STEP |
| 14 | AT_Wave | 2.000s | 66 | 22 | 22 | 22 | STEP |

## Manifest sortOrder → GLB index 映射

| manifestClipIndex | sortOrder | clipName | gltfAnimationIndex |
|-------------------|-----------|----------|-------------------|
| 0 | 0 | AT_Idle | 6 |
| 1 | 1 | AT_Listening | 7 |
| 2 | 2 | AT_Thinking | 12 |
| 3 | 3 | AT_Speaking | 11 |
| 4 | 4 | AT_Greeting | 4 |
| 5 | 5 | AT_Wave | 14 |
| 6 | 6 | AT_Nod | 8 |
| 7 | 7 | AT_ShakeHead | 10 |
| 8 | 8 | AT_Happy | 5 |
| 9 | 9 | AT_Confused | 3 |
| 10 | 10 | AT_Sad | 9 |
| 11 | 11 | AT_Angry | 0 |
| 12 | 12 | AT_TouchReaction | 13 |
| 13 | 13 | AT_Celebrate | 2 |
| 14 | 14 | AT_Apology | 1 |

## 关键事实修正

1. **AT_Wave**: manifestClipIndex=5, gltfAnimationIndex=14 (历史报告错误写成 index=0)
2. **AT_Thinking**: manifestClipIndex=2, gltfAnimationIndex=12
3. **AT_Idle**: manifestClipIndex=0, gltfAnimationIndex=6
4. **插值类型**: 全部为 **STEP** (历史报告错误写成 LINEAR)
5. 所有动画 channels=66 (rot=22, trans=22, scale=22),samplers=66
6. 动作包节点使用标准 HumanoidBone 名称(如 RightUpperArm),无需复杂映射

## AT_Wave 右臂通道详情

| channelIdx | nodeIdx | nodeName | path | sampler |
|------------|---------|----------|------|---------|
| 54 | 17 | RightShoulder | translation | 54 |
| 55 | 17 | RightShoulder | rotation | 55 |
| 56 | 17 | RightShoulder | scale | 56 |
| 57 | 16 | RightUpperArm | translation | 57 |
| 58 | 16 | RightUpperArm | rotation | 58 |
| 59 | 16 | RightUpperArm | scale | 59 |
| 60 | 15 | RightLowerArm | translation | 60 |
| 61 | 15 | RightLowerArm | rotation | 61 |
| 62 | 15 | RightLowerArm | scale | 62 |
| 63 | 14 | RightHand | translation | 63 |
| 64 | 14 | RightHand | rotation | 64 |
| 65 | 14 | RightHand | scale | 65 |

## 设计决策

- 运行时按 **clipName** 查找 GLB animation(不依赖 gltfAnimationIndex)
- manifestClipIndex 仅用于 UI 排序和动作卡片标识
- 解析器需正确处理 STEP 插值(保持前一个关键帧值)
