# Third Party Notices

本目录下的 VRM Viewer 实现参考了以下开源项目。

## Figure

- 项目:Figure - VRM & VRMA Model Viewer for Web
- 仓库:https://github.com/flarom/figure
- 用途:ArkTavern VRM Viewer 的主要参考实现。ArkWeb 版本将 Figure 的核心逻辑(Three.js + three-vrm 渲染管线、模型加载、动画播放、表情控制等)工程化拆分并迁移到 HarmonyOS ArkWeb 环境。
- 许可证:MIT License(见下方)
- 版权声明:Copyright (c) Figure

```
MIT License

Copyright (c) Figure

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Three.js

- 项目:three.js
- 仓库:https://github.com/mrdoob/three.js
- 版本:0.176.0(与 Figure `reference/figure-main/index.html` import map 中声明的 `three@0.176.0` 一致)
- 来源:从 npm 官方源 `npm install three@0.176.0` 安装后,从 `node_modules/three/build/` 与 `node_modules/three/examples/jsm/` 复制到本地 `vendor/three/`
- 本地文件:
  - `vendor/three/three.module.js`(WebGL Renderer 模块,内部 import `./three.core.js`)
  - `vendor/three/three.core.js`(Three.js 核心模块)
  - `vendor/three/controls/OrbitControls.js`(轨道控制器,内部 import `'three'` 由 import map 解析)
  - `vendor/three/loaders/GLTFLoader.js`(glTF / VRM 加载器,Phase 1C-1 引入;内部 import `'three'` 与 `'../utils/BufferGeometryUtils.js'`)
  - `vendor/three/utils/BufferGeometryUtils.js`(GLTFLoader 依赖,Phase 1C-1 引入;内部 import `'three'`)
  - `vendor/three/LICENSE`(MIT 许可证)
- 用途:ArkWeb VRM Viewer 的 3D 渲染核心。通过 `index.html` 中的 `<script type="importmap">` 将 bare specifier `three` 与 `three/addons/` 映射到本地路径,运行时禁止依赖 CDN。
- 许可证:MIT License(见下方)

```
The MIT License

Copyright © 2010-2025 Three.js Authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## @pixiv/three-vrm

- 项目:@pixiv/three-vrm
- 仓库:https://github.com/pixiv/three-vrm
- 版本:**3.5.5**
  - Figure `reference/figure-main/index.html` import map 声明 `@pixiv/three-vrm@3`(大版本范围)
  - npm registry `dist-tags.latest` 3.x = 3.5.5(jsdelivr `@3` 解析到的精确版本)
  - peerDependencies: `three ">=0.137"` → 与本地 three@0.176.0 兼容
- 来源:通过 `tools/vrm-vendor/` 工具锁定 `@pixiv/three-vrm@3.5.5`,使用 esbuild 打包为 ESM bundle,Three.js 设为 external(运行时复用 import map 中的 three@0.176.0)
- bundle 工具:`tools/vrm-vendor/build.mjs`(esbuild 0.24.2,`external: ['three', 'three/*']`)
- bundle 入口:`@pixiv/three-vrm/lib/three-vrm.module.js`(package.json `exports["."].import`)
- 本地文件:
  - `vendor/pixiv/three-vrm.module.js`(esbuild ESM bundle,278.4 KB,内部 48 处 `import ... from "three"` 由 import map 解析)
  - `vendor/pixiv/licenses/three-vrm.LICENSE`(MIT)
  - `vendor/pixiv/licenses/three-vrm-core.LICENSE`(MIT)
  - `vendor/pixiv/licenses/three-vrm-springbone.LICENSE`(MIT)
  - `vendor/pixiv/licenses/three-vrm-materials-mtoon.LICENSE`(MIT)
  - `vendor/pixiv/licenses/three-vrm-node-constraint.LICENSE`(MIT)
  - `vendor/pixiv/licenses/three-vrm-materials-v0compat.LICENSE`(MIT)
  - `vendor/pixiv/licenses/three-vrm-materials-hdr-emissive-multiplier.LICENSE`(MIT)
- bundle 包含的 Pixiv 子包(均 3.5.5,作为 bundled dependencies 打入 three-vrm.module.js):
  - `@pixiv/three-vrm-core`(核心:VRM 加载 / Humanoid / Expression / LookAt / Meta)
  - `@pixiv/three-vrm-springbone`(Spring Bone 物理)
  - `@pixiv/three-vrm-materials-mtoon`(MToon 材质)
  - `@pixiv/three-vrm-node-constraint`(节点约束)
  - `@pixiv/three-vrm-materials-v0compat`(VRM 0.x 材质兼容)
  - `@pixiv/three-vrm-materials-hdr-emissive-multiplier`(HDR 发射强度)
- 用途:VRM 文件加载与运行时支持。通过 `index.html` import map 将 `@pixiv/three-vrm` 映射到本地 `vendor/pixiv/three-vrm.module.js`,运行时禁止依赖 CDN。
- 关键约束:three-vrm bundle 必须复用 import map 中的 three@0.176.0,不得把第二份 Three.js 打入 bundle(否则 instanceof / Object3D 类型不一致,插件行为异常)。已通过 esbuild `external: ['three', 'three/*']` 保证。
- 许可证:MIT License(见下方,所有 Pixiv 子包均为 MIT)

```
MIT License

Copyright (c) 2020 pixiv inc.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## three-vrm-animation(后续阶段引入)

- 项目:@pixiv/three-vrm-animation
- 仓库:https://github.com/pixiv/three-vrm-animation
- 许可证:MIT License

---

## 说明

- ArkTavern 不直接复制 Figure 仓库的完整代码,而是将 Figure 的实现逻辑工程化拆分到 `scripts/viewer/` 下的多个模块。
- 所有从 Figure 迁移的逻辑保留版权声明与来源记录。
- Figure 与 OWNverse 实现冲突时,以 Figure 的明确源码实现为准。
- OWNverse 仅用于交叉验证架构、生命周期、错误处理与资源释放,不复制其压缩 bundle。
