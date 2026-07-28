/**
 * ViewerScene — Three.js Scene / Renderer / Lights / Test Object 管理
 *
 * 职责:
 *   - 创建 WebGLRenderer
 *   - 创建 Scene 与背景色
 *   - 创建 DirectionalLight / AmbientLight(强度 0,保留接口)
 *   - 创建测试 Mesh(BoxGeometry + MeshStandardMaterial),Phase 1B 验证用
 *   - 挂载 Canvas 到容器
 *   - Resize
 *   - Render
 *   - Dispose(递归释放 Geometry / Material / Texture)
 *
 * Reference:
 *   - figure-main/index.html initThree():
 *       WebGLRenderer({ antialias: true }), setPixelRatio(1),
 *       outputEncoding = sRGBEncoding, Scene background '#222222',
 *       DirectionalLight(0xffffff, 3.0) position (1,1,1).normalize(),
 *       AmbientLight(0xffffff, 0.0)
 *   - figure-main/index.html disposeVrm(): 递归释放 Geometry/Material/Texture 思路
 *   - ownverse-vrm-viewer/analysis/SCENE_PIPELINE.md: createRenderer/createScene/setupLight 交叉验证
 *
 * 与 Figure 的差异:
 *   - Figure 用 outputEncoding = sRGBEncoding(0.176 已废弃),本实现用 outputColorSpace = SRGBColorSpace(0.176 推荐 API,等效)
 *   - Figure 在 IIFE 中初始化,本实现拆分为独立类
 *   - Figure 不 dispose renderer,本实现补充完整 dispose 链路(forceContextLoss)
 *
 * Phase 1B 限制:
 *   - 仅创建测试物体(BoxGeometry),不加载 VRM
 *   - 不实现 TransformControls / GroundShadow / LightMarker(后续阶段)
 */
import * as THREE from 'three';

/** 错误代码:WebGL 不支持 */
export var WEBGL_NOT_SUPPORTED = 'WEBGL_NOT_SUPPORTED';
/** 错误代码:Scene 初始化失败 */
export var SCENE_INITIALIZATION_FAILED = 'SCENE_INITIALIZATION_FAILED';

/**
 * 递归释放 THREE.Material 及其关联的 Texture。
 * 后续 Phase 1C 加载 VRM 时复用。
 * @param {THREE.Material} material
 */
export function disposeMaterial(material) {
  if (!material) return;
  // 释放关联纹理(覆盖常见 map 通道)
  var textureKeys = [
    'map', 'normalMap', 'roughnessMap', 'metalnessMap',
    'emissiveMap', 'aoMap', 'bumpMap', 'alphaMap',
    'envMap', 'specularMap', 'displacementMap'
  ];
  textureKeys.forEach(function (key) {
    var tex = material[key];
    if (tex && typeof tex.dispose === 'function') {
      try { tex.dispose(); } catch (e) { /* ignore */ }
    }
  });
  if (typeof material.dispose === 'function') {
    try { material.dispose(); } catch (e) { /* ignore */ }
  }
}

/**
 * 递归释放 THREE.Object3D 子树中的 Geometry / Material / Texture。
 * 后续 Phase 1C 加载 VRM 时复用。
 * @param {THREE.Object3D} root
 */
export function disposeObject3D(root) {
  if (!root) return;
  root.traverse(function (obj) {
    if (obj.isMesh || obj.isLine || obj.isPoints) {
      if (obj.geometry && typeof obj.geometry.dispose === 'function') {
        try { obj.geometry.dispose(); } catch (e) { /* ignore */ }
      }
      if (obj.material) {
        if (Array.isArray(obj.material)) {
          obj.material.forEach(disposeMaterial);
        } else {
          disposeMaterial(obj.material);
        }
      }
    }
  });
}

export class ViewerScene {
  constructor() {
    /** @type {THREE.WebGLRenderer|null} */
    this.renderer = null;
    /** @type {THREE.Scene|null} */
    this.scene = null;
    /** @type {THREE.DirectionalLight|null} */
    this.directionalLight = null;
    /** @type {THREE.AmbientLight|null} */
    this.ambientLight = null;
    /** @type {THREE.Mesh|null} Phase 1B 测试物体 */
    this.testObject = null;
    /** @type {HTMLElement|null} */
    this.container = null;
    /** 标记是否已销毁,防止 dispose 后继续 render */
    this._disposed = false;
  }

  /**
   * 初始化 Renderer / Scene / Lights / 测试物体。
   * @param {HTMLElement} container 父容器,Canvas 将挂载于此
   * @returns {Promise<void>}
   * @throws {Error} WebGL 不支持时抛出 code=WEBGL_NOT_SUPPORTED
   */
  async initialize(container) {
    if (!container) {
      var err = new Error('container is required');
      err.code = SCENE_INITIALIZATION_FAILED;
      throw err;
    }
    this.container = container;
    var width = container.clientWidth || 1;
    var height = container.clientHeight || 1;

    // ===== Renderer =====
    // Figure: new WebGLRenderer({ antialias: true })
    // Figure: setPixelRatio(1), outputEncoding = sRGBEncoding
    // 0.176 适配:用 outputColorSpace = SRGBColorSpace 替代废弃的 outputEncoding
    try {
      this.renderer = new THREE.WebGLRenderer({ antialias: true });
    } catch (e) {
      var webglErr = new Error('WebGL not supported: ' + (e && e.message ? e.message : String(e)));
      webglErr.code = WEBGL_NOT_SUPPORTED;
      throw webglErr;
    }
    this.renderer.setPixelRatio(1);
    // 0.176 推荐 API,等效于 Figure 的 outputEncoding = sRGBEncoding
    this.renderer.outputColorSpace = THREE.SRGBColorSpace;
    // false: 不更新 canvas 的 CSS style,由我们手动控制
    this.renderer.setSize(width, height, false);
    this.renderer.domElement.className = 'viewer-canvas';
    this.renderer.domElement.style.display = 'block';
    this.renderer.domElement.style.width = '100%';
    this.renderer.domElement.style.height = '100%';
    // Figure: renderer.domElement.style.touchAction = 'none'
    this.renderer.domElement.style.touchAction = 'none';
    container.appendChild(this.renderer.domElement);

    // ===== Scene =====
    this.scene = new THREE.Scene();
    // Figure: scene.background = new Color('#222222')
    this.scene.background = new THREE.Color('#222222');

    // ===== Lights =====
    // Figure: DirectionalLight(0xffffff, 3.0), position (1,1,1).normalize()
    this.directionalLight = new THREE.DirectionalLight(0xffffff, 3.0);
    this.directionalLight.position.set(1.0, 1.0, 1.0).normalize();
    this.scene.add(this.directionalLight);

    // Figure: AmbientLight(0xffffff, 0.0) —— 强度 0,保留接口供后续灯光面板
    this.ambientLight = new THREE.AmbientLight(0xffffff, 0.0);
    this.scene.add(this.ambientLight);

    // ===== 测试物体(Phase 1B 验证用) =====
    // 位置 (0, 1.0, 0) 在默认相机视野内(camera at (0, 1.25, 2) target (0, 1.25, 0))
    var geometry = new THREE.BoxGeometry(0.5, 0.5, 0.5);
    var material = new THREE.MeshStandardMaterial({ color: 0x4fc3f7 });
    this.testObject = new THREE.Mesh(geometry, material);
    this.testObject.position.set(0, 1.0, 0);
    this.scene.add(this.testObject);
  }

  /**
   * 调整 Renderer 尺寸。
   * 注意:Camera aspect 由 ViewerCamera 单独更新。
   * @param {number} width
   * @param {number} height
   */
  resize(width, height) {
    if (this._disposed || !this.renderer) return;
    if (width <= 0 || height <= 0) return;
    this.renderer.setSize(width, height, false);
  }

  /**
   * 渲染一帧。
   * @param {THREE.Camera} camera
   */
  render(camera) {
    if (this._disposed || !this.renderer || !this.scene) return;
    this.renderer.render(this.scene, camera);
  }

  /** @returns {THREE.WebGLRenderer|null} */
  getRenderer() { return this.renderer; }

  /** @returns {THREE.Scene|null} */
  getScene() { return this.scene; }

  /** @returns {THREE.Mesh|null} */
  getTestObject() { return this.testObject; }

  /** @returns {THREE.DirectionalLight|null} */
  getDirectionalLight() { return this.directionalLight; }

  /** @returns {THREE.AmbientLight|null} */
  getAmbientLight() { return this.ambientLight; }

  // ===== Phase 1C-2: 模型挂载接口 =====

  /**
   * 将 VRM 模型根节点加入 Scene。
   * 由 ViewerCore 在 ModelLoader 状态变为 READY 时调用。
   * @param {THREE.Object3D} object3D VRM scene 根节点
   */
  addModel(object3D) {
    if (this._disposed || !this.scene || !object3D) return;
    this.scene.add(object3D);
  }

  /**
   * 从 Scene 移除 VRM 模型根节点(不移除资源,资源释放由 ModelLoader._disposeVrm 完成)。
   * @param {THREE.Object3D} object3D
   */
  removeModel(object3D) {
    if (!object3D) return;
    if (object3D.parent) {
      object3D.parent.remove(object3D);
    }
  }

  /**
   * 移除并释放测试方块(Phase 1B 遗留物体)。
   * 模型加载成功后调用,让出 Scene 给真实 VRM。
   * 模型加载失败时不调用,保留测试方块以确认 Three.js Scene 仍正常。
   */
  removeTestObject() {
    if (this.testObject) {
      disposeObject3D(this.testObject);
      if (this.scene) this.scene.remove(this.testObject);
      this.testObject = null;
    }
  }

  /**
   * 释放所有 GPU 资源。
   *
   * 顺序(参考 AGENTS.md Phase 1B 要求):
   *   1. 遍历测试物体,dispose Geometry / Material / Texture
   *   2. 从 Scene 移除测试物体 / 灯光
   *   3. renderer.renderLists.dispose()
   *   4. renderer.dispose()
   *   5. forceContextLoss(存在时)
   *   6. 移除 Canvas
   *   7. 清空 Scene / 引用
   */
  dispose() {
    if (this._disposed) return;
    this._disposed = true;

    // 1. 释放测试物体(Geometry / Material)
    if (this.testObject) {
      disposeObject3D(this.testObject);
      if (this.scene) this.scene.remove(this.testObject);
      this.testObject = null;
    }

    // 2. 移除灯光
    if (this.directionalLight && this.scene) {
      this.scene.remove(this.directionalLight);
    }
    this.directionalLight = null;

    if (this.ambientLight && this.scene) {
      this.scene.remove(this.ambientLight);
    }
    this.ambientLight = null;

    // 3-6. 释放 Renderer
    if (this.renderer) {
      try { this.renderer.renderLists.dispose(); } catch (e) { /* ignore */ }
      try { this.renderer.dispose(); } catch (e) { /* ignore */ }
      // 强制释放 WebGL 上下文(若 API 可用)
      if (typeof this.renderer.forceContextLoss === 'function') {
        try { this.renderer.forceContextLoss(); } catch (e) { /* ignore */ }
      }
      // 移除 Canvas
      if (this.renderer.domElement && this.renderer.domElement.parentNode) {
        this.renderer.domElement.parentNode.removeChild(this.renderer.domElement);
      }
      this.renderer = null;
    }

    // 7. 清空 Scene / 引用
    this.scene = null;
    this.container = null;
  }
}
