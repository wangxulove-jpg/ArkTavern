# T-3D.6B 在线动作资源研究报告

## 1. 概述

本报告记录 ArkTavern 项目 T-3D.6B 阶段的在线动作资源研究、选型、下载、校验与导入闭环验证结果。

**核心结论**:已成功建立从在线资源获取到应用内导入的完整闭环,选用 Khronos glTF Sample Assets 仓库的 Fox.glb(CC0 + CC BY 4.0 授权)作为开发测试动作,验证了下载、解析、预览、确认、持久化、恢复、删除全流程。

## 2. 研究目标

1. 自主联网搜索合法动作资源(优先 Khronos glTF Sample Assets、VRM Consortium、Mixamo)
2. 至少找到 3 个候选,记录来源、授权、校验值
3. 下载到 `.agent-cache/character-actions/` 目录(已加入 .gitignore)
4. 完成真实动作导入闭环
5. 不提交下载的资源文件到 Git

## 3. 候选资源评估

### 3.1 评估标准

- **授权明确**:必须是有清晰授权条款的资源(CC0、CC BY、Apache 2.0 等)
- **格式兼容**:GLB 或 glTF 格式,包含骨骼动画
- **骨骼结构**:优先 Humanoid 兼容骨骼(VRM0/VRM1/Mixamo)
- **文件大小**:适合移动端(建议 < 5MB)
- **来源可靠**:官方仓库或知名开源项目

### 3.2 候选列表

| 资源 | 来源 | 授权 | 骨骼类型 | 决策 |
|------|------|------|----------|------|
| Fox.glb | Khronos glTF-Sample-Assets | CC0 + CC BY 4.0 | Mixamo-style(24 joints) | **选定** |
| RiggedFigure.glb | Khronos glTF-Sample-Assets | CC BY 4.0 | 人形(含动画) | 拒绝:动画为展示用,非标准动作 |
| RiggedSimple.glb | Khronos glTF-Sample-Assets | CC BY 4.0 | 简单人形 | 拒绝:仅 2 个骨骼,非完整人形 |
| VRM Sample Models | VRM Consortium | CC BY 4.0 | VRM0/VRM1 | 拒绝:VRM 文件需额外解析器,当前阶段聚焦 GLB |
| Mixamo Animations | Adobe Mixamo | Mixabo ToS(禁止分发) | Mixamo | 拒绝:授权条款禁止随应用分发,仅可个人使用 |
| Blender Sample | Blender Foundation | CC0 | 人形 | 拒绝:无标准动作动画 |
| Ready Player Me | Ready Player Me | RPM ToS | 人形 | 拒绝:需 API 注册,非静态资源 |

### 3.3 被拒绝来源(禁止清单)

- Adobe Mixamo:服务条款禁止资源再分发,不可作为应用默认资产
- Sketchfab 付费模型:版权不明确
- 非官方镜像站:无法验证授权与完整性

## 4. 选定资源:Fox.glb

### 4.1 基本信息

- **文件名**: Fox.glb
- **来源**: Khronos Group glTF-Sample-Assets 仓库
- **URL**: `https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/main/Models/Fox/glTF-Binary/Fox.glb`
- **下载时间**: 2026-07-23
- **文件大小**: 162852 bytes (约 159 KB)
- **SHA256**: `D97044E701822BAC5A62696459B27D7B375AADA5DE8574ED4362EDBBA94771F7`

### 4.2 授权信息

- **模型**: CC0 1.0 Universal(公共领域)
- **骨骼绑定与动画**: CC BY 4.0(署名 Tomasz Lechociński)
- **结论**: 可用于个人项目开发测试,分发时需保留 CC BY 4.0 署名

### 4.3 GLB 结构分析

```
Header: magic=glTF, version=2, length=162852
JSON chunk: length=8748
BIN chunk: length=154092

Animations: 3
  - Survey (3.42s)
  - Walk
  - Run

Nodes: 26
Skins: 1 (24 joints)

骨骼命名: Mixamo-style (b_Root_00, b_Hip_01, b_Spine_02, ...)
```

### 4.4 骨骼兼容性

- **识别 Profile**: VRM 0.x(Mixamo-style 命名被 mapper 识别为 VRM 0.x)
- **兼容等级**: 部分人形(PartialHumanoid)
- **缺失骨骼**: Hips, LeftUpperLeg, RightUpperLeg
- **说明**: Fox 模型为四足动物,骨骼结构与标准 Humanoid 二足骨骼部分匹配,部分缺失

## 5. HarmonyOS ArkGraphics3D SDK 限制

### 5.1 已知限制

1. **不支持运行时跨模型动画重定向**:无法将 Fox.glb 的动画应用到其他模型上
2. **Animation API 无 name 属性**:只能通过 `scene.animations[index]` 索引访问
3. **DocumentViewPicker 在模拟器中无响应**:系统文件选择器在模拟器环境下不可用

### 5.2 应对策略

- **DocumentViewPicker 不可用**:增加开发构建可见的"加载测试动作"入口,通过 HTTP 下载到应用沙盒
- **跨模型重定向不支持**:动作兼容性分级处理(Direct/Mapped/EmbeddedOnly/MetadataOnly/Unsupported)
- **Animation 索引访问**:通过 GltfAnimationParser 解析 GLB 元数据,记录 clip 名称与索引映射

## 6. 导入闭环设计

### 6.1 流程

```
用户点击"加载测试动作"
  ↓
检查 filesDir/dev_action_test/Fox.glb 是否存在
  ↓ (不存在)
HTTP GET 下载 Fox.glb 到沙盒
  ↓
importActionFromLocalDevPath() 调用标准导入流程
  ↓
importActionPreview() 解析 GLB
  ↓
显示导入预览对话框(文件名/格式/Clip数/骨骼节点/Profile/兼容等级/缺失骨骼)
  ↓
用户选择 Clip 和目标槽位
  ↓
用户点击"确认导入"
  ↓
持久化到 files/character_actions/{actionId}/action.glb + metadata.json
  ↓
更新槽位绑定
  ↓
动作资产库显示已导入资产
```

### 6.2 持久化结构

```
files/
└── character_actions/
    └── {actionId}/
        ├── action.glb        (动作文件副本)
        └── metadata.json     (动作元数据)
```

### 6.3 动作兼容性分级

| 等级 | 含义 | 处理方式 |
|------|------|----------|
| Direct | 骨骼完全匹配,可直接播放 | 绑定到槽位,运行时播放 |
| Mapped | 骨骼部分匹配,可重定向 | 绑定到槽位,运行时映射播放 |
| EmbeddedOnly | 仅模型内置动画可播放 | 仅记录元数据,不跨模型播放 |
| MetadataOnly | SDK 不支持播放 | 仅记录元数据,UI 提示不可播放 |
| Unsupported | 不支持 | 拒绝导入 |

## 7. 设备验收结果

### 7.1 验收环境

- 设备: HarmonyOS 模拟器 (127.0.0.1:5555)
- 屏幕: 1224 x 2776
- 应用版本: 前序会话编译的 HAP(T-3D.6A + T-3D.6B 代码)

### 7.2 验收项目

| # | 验收项 | 结果 | 说明 |
|---|--------|------|------|
| 1 | 在线获取 | ✅ 通过 | HTTP GET 下载 Fox.glb(162852 bytes)到 filesDir/dev_action_test/ |
| 2 | Download 存储 | ✅ 通过 | 文件保存到应用沙盒,checkDevTestFileExists 确认存在 |
| 3 | 导入闭环 | ✅ 通过 | 解析 GLB → 预览对话框 → 确认导入 → 持久化 → 列表显示 |
| 4 | 恢复 | ✅ 通过 | 前序会话导入的动作在本次会话重启后仍存在(动作资产库显示 2 项) |
| 5 | 删除 | ✅ 通过 | doubleClick 触发删除,列表变空显示"暂无导入的动作资产" |

### 7.3 预览对话框验证

导入预览对话框完整显示以下信息:
- 文件名: Fox.glb
- 格式: 外部 GLB
- Clip 数: 3
- 骨骼节点: 26
- 骨骼 Profile: VRM 0.x
- 兼容等级: 部分人形
- 缺失骨骼: Hips, LeftUpperLeg, RightUpperLeg
- Clip 选择: 支持
- 槽位选择: 支持

### 7.4 已知问题

1. **uitest single click 在删除按钮上不生效**:需用 doubleClick 触发,原因待查(可能与 ArkUI Button 事件处理有关)
2. **命令行 hvigorw 报 SDK component missing**:IDE 内部编译可用,命令行环境变量需额外配置
3. **骨骼 Profile 识别**:Mixamo-style 命名被识别为 VRM 0.x,后续需优化 HumanoidBoneMapper 识别逻辑

## 8. 工作边界遵守情况

- ✅ 只下载授权明确资源(CC0 + CC BY 4.0)
- ✅ 不使用盗版/破解资源
- ✅ 不绕过登录
- ✅ 不把"可个人使用"等同"允许随应用分发"(Mixamo 被拒绝)
- ✅ 不把下载资源提交进 Git(.agent-cache/ 已加入 .gitignore)
- ✅ 记录来源、授权、下载时间和校验值(SOURCE.txt, SHA256.txt)
- ✅ 不把动作文件成功解析描述成"任意模型已能播放"(明确说明 SDK 不支持跨模型重定向)

## 9. 结论与后续工作

### 9.1 结论

T-3D.6B 在线动作资源获取、下载与导入闭环已验证通过。选用 Khronos glTF Sample Assets 的 Fox.glb 作为开发测试动作,完整闭环(下载→解析→预览→确认→持久化→恢复→删除)在模拟器上全部通过。

### 9.2 后续工作(T-3D.6C)

- 聊天状态动作联动:根据聊天状态(待机/思考/说话/触摸反应)自动切换动作
- 动作预览 3D 渲染:在导入预览对话框中渲染 3D 模型预览动作
- 骨骼映射优化:改进 HumanoidBoneMapper 对 Mixamo-style 命名的识别
- 正式发布前移除开发模式入口(IS_DEV_BUILD = false)

## 10. 资源元数据文件

详细元数据见:
- `.agent-cache/character-actions/candidates.json` - 候选资源完整元数据
- `.agent-cache/character-actions/selected/LICENSE.txt` - Fox.glb 许可证
- `.agent-cache/character-actions/selected/SOURCE.txt` - Fox.glb 来源记录
- `.agent-cache/character-actions/selected/SHA256.txt` - Fox.glb 校验值
- `.agent-cache/character-actions/rejected/rejection_notes.json` - 被拒绝候选原因
