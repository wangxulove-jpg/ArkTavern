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
/** Phase 2A-1: 错误代码:背景颜色无效 */
export var SCENE_BACKGROUND_INVALID = 'SCENE_BACKGROUND_INVALID';
/** Phase 2A-1: 错误代码:灯光强度无效 */
export var SCENE_LIGHT_INTENSITY_INVALID = 'SCENE_LIGHT_INTENSITY_INVALID';

// ===== Phase 2F: 环境贴图错误码 =====
/** 环境初始化失败 */
export var ERR_ENVIRONMENT_INITIALIZATION_FAILED = 'ENVIRONMENT_INITIALIZATION_FAILED';
/** 环境来源不可用 */
export var ERR_ENVIRONMENT_SOURCE_UNAVAILABLE = 'ENVIRONMENT_SOURCE_UNAVAILABLE';
/** 环境未就绪(初始化未完成或失败) */
export var ERR_ENVIRONMENT_NOT_READY = 'ENVIRONMENT_NOT_READY';
/** 环境未启用 */
export var ERR_ENVIRONMENT_NOT_ENABLED = 'ENVIRONMENT_NOT_ENABLED';
/** 环境纹理缺失 */
export var ERR_ENVIRONMENT_TEXTURE_MISSING = 'ENVIRONMENT_TEXTURE_MISSING';
/** 环境启用参数无效 */
export var ERR_ENVIRONMENT_ENABLED_INVALID = 'ENVIRONMENT_ENABLED_INVALID';

/**
 * Phase 3B: 测试立方体 Debug 开关。
 *
 * - false (默认,生产模式): 不创建测试立方体,正式页面显示空场景或真实模型
 * - true (仅 Debug): 创建 BoxGeometry 测试立方体用于 Three.js Scene 验证
 *
 * 历史背景:
 * - Phase 1B 时无条件创建测试立方体用于验证 WebGL 渲染管线
 * - Phase 3B 起,模型持久化与自动恢复完成后,正式页面不再需要测试立方体
 * - 保留开关以便 Debug 场景下快速验证 Scene/Camera/Renderer 是否正常
 */
var ENABLE_DEBUG_TEST_CUBE = false;
/** 天空盒可见参数无效 */
export var ERR_SKYBOX_VISIBLE_INVALID = 'SKYBOX_VISIBLE_INVALID';
/** 环境强度参数无效 */
export var ERR_ENVIRONMENT_INTENSITY_INVALID = 'ENVIRONMENT_INTENSITY_INVALID';
/** 环境强度不支持 */
export var ERR_ENVIRONMENT_INTENSITY_UNSUPPORTED = 'ENVIRONMENT_INTENSITY_UNSUPPORTED';
/** 环境正在初始化中 */
export var ERR_ENVIRONMENT_ALREADY_INITIALIZING = 'ENVIRONMENT_ALREADY_INITIALIZING';
/** 环境已销毁 */
export var ERR_ENVIRONMENT_DISPOSED = 'ENVIRONMENT_DISPOSED';

// ===== Phase 2F: 环境状态枚举 =====
/**
 * Phase 2F: 环境贴图状态机。
 *
 * 状态流转:
 *   UNINITIALIZED → INITIALIZING → READY
 *   INITIALIZING → FAILED
 *   任意 → DISPOSED
 */
export var EnvironmentState = Object.freeze({
  UNINITIALIZED: 'UNINITIALIZED',
  INITIALIZING: 'INITIALIZING',
  READY: 'READY',
  FAILED: 'FAILED',
  DISPOSED: 'DISPOSED'
});

/** Phase 2F: 环境来源常量 */
export var ENVIRONMENT_SOURCE_ROOM = 'ROOM_ENVIRONMENT';
export var ENVIRONMENT_SOURCE_NONE = 'NONE';

/** Phase 2F: 环境强度合法范围 */
var ENVIRONMENT_INTENSITY_MIN = 0.0;
var ENVIRONMENT_INTENSITY_MAX = 2.0;
/** Phase 2F: 环境强度默认值 */
var ENVIRONMENT_INTENSITY_DEFAULT = 1.0;

/**
 * Phase 2A-1: 校验 #RRGGBB 颜色格式。
 *
 * 只允许:
 * - #RRGGBB(6 位十六进制)
 *
 * 禁止:
 * - 任意 CSS(rgba / hsl / url(...) 等)
 * - 脚本字符串
 * - 3 位简写(#FFF)
 * - 带透明度(#RRGGBBAA)
 *
 * @param {string} color
 * @returns {boolean}
 */
function isValidHexColor(color) {
  if (typeof color !== 'string') return false;
  return /^#[0-9A-Fa-f]{6}$/.test(color);
}

/**
 * Phase 2A-1: 将颜色规范化为大写 #RRGGBB。
 *
 * @param {string} color 已通过 isValidHexColor 校验的颜色
 * @returns {string}
 */
function normalizeHexColor(color) {
  return color.toUpperCase();
}

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
    /**
     * Phase 2A-1: 网格助手(GridHelper)。
     *
     * 在 initialize 中创建一次,默认 visible=false。
     * 切换网格显示只修改 gridHelper.visible,不重复创建。
     * dispose 时释放其 geometry 和 material。
     *
     * @type {THREE.GridHelper|null}
     */
    this.gridHelper = null;
    /**
     * Phase 2A-1: 当前背景颜色(规范化为大写 #RRGGBB)。
     *
     * 与 scene.background 的实际值保持同步,供 getSettings 返回。
     * 默认 '#222222'(与 Figure 一致)。
     *
     * @type {string}
     */
    this.backgroundColor = '#222222';
    /**
     * Phase 2A-1: 当前主方向光强度(0.0 ~ 4.0)。
     *
     * 与 directionalLight.intensity 保持同步,供 getSettings 返回。
     * 默认 3.0(与 Figure 一致)。
     *
     * @type {number}
     */
    this.lightIntensity = 3.0;
    /** @type {HTMLElement|null} */
    this.container = null;
    /** 标记是否已销毁,防止 dispose 后继续 render */
    this._disposed = false;

    // ===== Phase 2F: 环境贴图状态 =====
    /** @type {string} 环境状态 (EnvironmentState 枚举) */
    this.environmentState = EnvironmentState.UNINITIALIZED;
    /** @type {string} 环境来源 (ROOM_ENVIRONMENT / NONE) */
    this.environmentSource = ENVIRONMENT_SOURCE_NONE;
    /** @type {THREE.Texture|null} PMREM 生成的环境纹理 */
    this.environmentTexture = null;
    /** @type {THREE.WebGLRenderTarget|null} PMREM 渲染目标 */
    this.environmentRenderTarget = null;
    /** @type {THREE.PMREMGenerator|null} PMREM 生成器 */
    this.pmremGenerator = null;
    /** @type {boolean} 环境是否启用 */
    this.environmentEnabled = false;
    /** @type {boolean} 天空盒是否可见 */
    this.skyboxVisible = false;
    /** @type {number} 环境强度 (0.0 ~ 2.0) */
    this.environmentIntensity = ENVIRONMENT_INTENSITY_DEFAULT;
    /** @type {string} 环境最近错误码 */
    this.environmentErrorCode = '';
    /** @type {string} 环境最近错误信息 */
    this.environmentErrorMessage = '';
    /** @type {THREE.Color|null} 保存的纯色背景(Skybox 开启前) */
    this._savedBackgroundColor = null;
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

    // ===== 测试物体(Phase 1B 验证用,Phase 3B 默认关闭) =====
    // Phase 3B: 正式模式默认不创建测试立方体 (ENABLE_DEBUG_TEST_CUBE = false)
    // 仅在 Debug 场景下手动开启开关时创建,用于验证 Scene/Camera/Renderer
    if (ENABLE_DEBUG_TEST_CUBE) {
      var geometry = new THREE.BoxGeometry(0.5, 0.5, 0.5);
      var material = new THREE.MeshStandardMaterial({ color: 0x4fc3f7 });
      this.testObject = new THREE.Mesh(geometry, material);
      this.testObject.position.set(0, 1.0, 0);
      this.scene.add(this.testObject);
    } else {
      this.testObject = null;
    }

    // ===== Phase 2A-1: GridHelper =====
    // 只创建一次,默认 visible=false。切换网格显示只修改 gridHelper.visible。
    // 网格位置与角色脚底基准合理:y=0 平面,尺寸 10,每格 1 单位。
    // 颜色:中心线 0x888888 / 网格线 0x444444(暗色,不遮挡模型)。
    this.gridHelper = new THREE.GridHelper(10, 10, 0x888888, 0x444444);
    this.gridHelper.visible = false;
    this.gridHelper.position.set(0, 0, 0);
    this.scene.add(this.gridHelper);
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

  // ===== Phase 2A-1: Scene 设置 API =====

  /**
   * Phase 2A-1: 设置场景背景颜色。
   *
   * 只接受 #RRGGBB 格式(6 位十六进制)。
   * 无效颜色返回受控失败 { success: false, error: SCENE_BACKGROUND_INVALID },
   * 不抛到全局。
   *
   * 成功后:
   * - scene.background.set(color)
   * - this.backgroundColor 更新为规范化后的大写 #RRGGBB
   *
   * @param {string} color #RRGGBB 格式
   * @returns {{success: boolean, color?: string, error?: string}}
   */
  setBackgroundColor(color) {
    if (this._disposed) {
      return { success: false, error: 'SCENE_DISPOSED' };
    }
    if (!isValidHexColor(color)) {
      return { success: false, error: SCENE_BACKGROUND_INVALID };
    }
    if (!this.scene || !this.scene.background) {
      return { success: false, error: SCENE_INITIALIZATION_FAILED };
    }
    var normalized = normalizeHexColor(color);
    try {
      // Phase 2F: Skybox 开启时只保存颜色,不覆盖天空盒背景
      if (this.skyboxVisible) {
        // 只更新 backgroundColor 和 _savedBackgroundColor
        // 不修改 scene.background(保持环境纹理)
        if (this._savedBackgroundColor) {
          this._savedBackgroundColor.set(normalized);
        } else {
          this._savedBackgroundColor = new THREE.Color(normalized);
        }
      } else {
        // Skybox 关闭:直接更新 scene.background
        this.scene.background.set(normalized);
      }
    } catch (e) {
      return { success: false, error: SCENE_BACKGROUND_INVALID };
    }
    this.backgroundColor = normalized;
    return { success: true, color: normalized };
  }

  /**
   * Phase 2A-1: 查询当前背景颜色。
   *
   * @returns {{success: boolean, color?: string, error?: string}}
   */
  getBackgroundColor() {
    if (this._disposed) {
      return { success: false, error: 'SCENE_DISPOSED' };
    }
    if (!this.scene) {
      return { success: false, error: SCENE_INITIALIZATION_FAILED };
    }
    return { success: true, color: this.backgroundColor };
  }

  /**
   * Phase 2A-1: 设置网格显示。
   *
   * GridHelper 在 initialize 中已创建一次,此处只切换 visible。
   * 禁止每次切换时重复创建新的 GridHelper。
   *
   * @param {boolean} visible
   * @returns {{success: boolean, visible?: boolean, error?: string}}
   */
  setGridVisible(visible) {
    if (this._disposed) {
      return { success: false, error: 'SCENE_DISPOSED' };
    }
    if (typeof visible !== 'boolean') {
      return { success: false, error: 'INVALID_ARGUMENT' };
    }
    if (!this.gridHelper) {
      return { success: false, error: SCENE_INITIALIZATION_FAILED };
    }
    this.gridHelper.visible = visible;
    return { success: true, visible: this.gridHelper.visible };
  }

  /**
   * Phase 2A-1: 查询网格显示状态。
   *
   * @returns {{success: boolean, visible?: boolean, error?: string}}
   */
  getGridVisible() {
    if (this._disposed) {
      return { success: false, error: 'SCENE_DISPOSED' };
    }
    if (!this.gridHelper) {
      return { success: false, error: SCENE_INITIALIZATION_FAILED };
    }
    return { success: true, visible: !!this.gridHelper.visible };
  }

  /**
   * Phase 2A-1: 设置主方向光强度。
   *
   * 合法范围:0.0 ~ 4.0
   * 无效值返回 { success: false, error: SCENE_LIGHT_INTENSITY_INVALID }。
   *
   * ArkUI 百分比映射(由 ArkTS 端完成):
   *   0% → 0.0, 25% → 1.0, 50% → 2.0, 75% → 3.0, 100% → 4.0
   * 换算:intensity = percentage / 25.0
   *
   * @param {number} intensity 0.0 ~ 4.0
   * @returns {{success: boolean, intensity?: number, error?: string}}
   */
  setLightIntensity(intensity) {
    if (this._disposed) {
      return { success: false, error: 'SCENE_DISPOSED' };
    }
    if (typeof intensity !== 'number' || isNaN(intensity)) {
      return { success: false, error: SCENE_LIGHT_INTENSITY_INVALID };
    }
    if (intensity < 0.0 || intensity > 4.0) {
      return { success: false, error: SCENE_LIGHT_INTENSITY_INVALID };
    }
    if (!this.directionalLight) {
      return { success: false, error: SCENE_INITIALIZATION_FAILED };
    }
    this.directionalLight.intensity = intensity;
    this.lightIntensity = intensity;
    return { success: true, intensity: this.directionalLight.intensity };
  }

  /**
   * Phase 2A-1: 查询主方向光强度。
   *
   * @returns {{success: boolean, intensity?: number, error?: string}}
   */
  getLightIntensity() {
    if (this._disposed) {
      return { success: false, error: 'SCENE_DISPOSED' };
    }
    if (!this.directionalLight) {
      return { success: false, error: SCENE_INITIALIZATION_FAILED };
    }
    return { success: true, intensity: this.lightIntensity };
  }

  /**
   * Phase 2A-1: 获取场景设置快照(背景颜色 / 网格 / 灯光)。
   *
   * 供 ViewerCore.getSceneState() 和 Bridge getSceneSettings() 使用。
   *
   * @returns {{success: boolean, backgroundColor?: string, gridVisible?: boolean, lightIntensity?: number, error?: string}}
   */
  getSettings() {
    if (this._disposed) {
      return { success: false, error: 'SCENE_DISPOSED' };
    }
    if (!this.scene) {
      return { success: false, error: SCENE_INITIALIZATION_FAILED };
    }
    return {
      success: true,
      backgroundColor: this.backgroundColor,
      gridVisible: this.gridHelper ? !!this.gridHelper.visible : false,
      lightIntensity: this.lightIntensity
    };
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
  // ===== Phase 2F: 环境贴图 API =====

  /**
   * Phase 2F: 构建程序化环境场景(作为 PMREMGenerator.fromScene 的输入)。
   *
   * 构建 6 个 PlaneGeometry 作为房间内壁,每个面赋予不同亮度的发光材质,
   * 模拟室内间接光照:天花板最亮,地板中等,墙壁略暗。
   * 使用 emissive 而非灯光,确保 PMREM 能烘焙亮度。
   *
   * 场景尺寸:10x10x10 的立方体房间,相机在中心。
   * 注意:Plane 默认朝 +Z,需要旋转使法线朝向房间内部。
   *
   * @returns {THREE.Scene} 程序化环境场景
   */
  _buildProgrammaticEnvironmentScene() {
    var envScene = new THREE.Scene();
    var size = 10;

    // 房间内壁材质(朝向房间内部)
    // 天花板:最亮(0.9),地板:中等(0.4),墙壁:略暗(0.6)
    var ceilingColor = new THREE.Color(0.9, 0.9, 0.9);
    var floorColor = new THREE.Color(0.4, 0.4, 0.4);
    var wallColor = new THREE.Color(0.6, 0.6, 0.6);

    function makePlane(color, position, rotation) {
      var geometry = new THREE.PlaneGeometry(size, size);
      var material = new THREE.MeshBasicMaterial({ color: color });
      material.toneMapped = false;
      var mesh = new THREE.Mesh(geometry, material);
      mesh.position.copy(position);
      mesh.rotation.copy(rotation);
      return mesh;
    }

    // 天花板(y = size/2, 法线朝下 -Y)
    envScene.add(makePlane(
      ceilingColor,
      new THREE.Vector3(0, size / 2, 0),
      new THREE.Euler(Math.PI / 2, 0, 0)
    ));
    // 地板(y = -size/2, 法线朝上 +Y)
    envScene.add(makePlane(
      floorColor,
      new THREE.Vector3(0, -size / 2, 0),
      new THREE.Euler(-Math.PI / 2, 0, 0)
    ));
    // 后墙(z = -size/2, 法线朝 +Z)
    envScene.add(makePlane(
      wallColor,
      new THREE.Vector3(0, 0, -size / 2),
      new THREE.Euler(0, 0, 0)
    ));
    // 前墙(z = size/2, 法线朝 -Z)
    envScene.add(makePlane(
      wallColor,
      new THREE.Vector3(0, 0, size / 2),
      new THREE.Euler(0, Math.PI, 0)
    ));
    // 左墙(x = -size/2, 法线朝 +X)
    envScene.add(makePlane(
      wallColor,
      new THREE.Vector3(-size / 2, 0, 0),
      new THREE.Euler(0, Math.PI / 2, 0)
    ));
    // 右墙(x = size/2, 法线朝 -X)
    envScene.add(makePlane(
      wallColor,
      new THREE.Vector3(size / 2, 0, 0),
      new THREE.Euler(0, -Math.PI / 2, 0)
    ));

    return envScene;
  }

  /**
   * Phase 2F: 释放程序化环境场景中的 geometry/material。
   *
   * PMREMGenerator.fromScene 烘焙完成后,源场景不再需要,
   * 应立即释放其 geometry 和 material(不释放 texture,因为没有)。
   *
   * @param {THREE.Scene} envScene 程序化环境场景
   */
  _disposeProgrammaticEnvironmentScene(envScene) {
    if (!envScene) return;
    envScene.traverse(function (obj) {
      if (obj.isMesh) {
        if (obj.geometry && typeof obj.geometry.dispose === 'function') {
          try { obj.geometry.dispose(); } catch (e) { /* ignore */ }
        }
        if (obj.material) {
          if (Array.isArray(obj.material)) {
            obj.material.forEach(function (m) {
              if (m && typeof m.dispose === 'function') {
                try { m.dispose(); } catch (e) { /* ignore */ }
              }
            });
          } else if (typeof obj.material.dispose === 'function') {
            try { obj.material.dispose(); } catch (e) { /* ignore */ }
          }
        }
      }
    });
  }

  /**
   * Phase 2F: 初始化环境贴图。
   *
   * 使用程序化 RoomEnvironment 场景作为 PMREM 输入,生成环境纹理。
   * 同步执行(PMREMGenerator.fromScene 是同步的),但通过状态机管理便于未来扩展。
   *
   * 初始化完成后:
   *   - environmentState = READY
   *   - environmentTexture 已生成
   *   - environmentEnabled = false (默认不自动启用)
   *   - skyboxVisible = false (默认不显示天空盒)
   *   - environmentIntensity = 1.0 (默认值)
   *
   * 重复初始化:
   *   - READY → 返回当前状态(不重复创建资源)
   *   - INITIALIZING → 返回 ENVIRONMENT_ALREADY_INITIALIZING
   *   - DISPOSED → 返回 ENVIRONMENT_DISPOSED
   *
   * 失败处理:
   *   - environmentState = FAILED
   *   - 保留现有纯色背景和灯光
   *   - 不影响 ViewerState
   *
   * @returns {{success: boolean, state?: string, error?: {code: string, message: string}}}
   */
  initializeEnvironment() {
    if (this._disposed) {
      return {
        success: false,
        error: { code: ERR_ENVIRONMENT_DISPOSED, message: 'Scene disposed' }
      };
    }
    // READY:幂等返回(不重复创建资源)
    if (this.environmentState === EnvironmentState.READY) {
      return { success: true, state: this.environmentState };
    }
    // INITIALIZING:受控拒绝
    if (this.environmentState === EnvironmentState.INITIALIZING) {
      return {
        success: false,
        error: { code: ERR_ENVIRONMENT_ALREADY_INITIALIZING, message: 'Environment already initializing' }
      };
    }
    // DISPOSED:不可重新初始化
    if (this.environmentState === EnvironmentState.DISPOSED) {
      return {
        success: false,
        error: { code: ERR_ENVIRONMENT_DISPOSED, message: 'Environment disposed' }
      };
    }
    // FAILED:允许重试(从 FAILED 回到 INITIALIZING)
    if (this.environmentState === EnvironmentState.FAILED) {
      // 清除之前的错误状态
      this.environmentErrorCode = '';
      this.environmentErrorMessage = '';
      // 释放之前可能残留的资源
      this._disposeEnvironmentResources();
    }

    if (!this.renderer) {
      this.environmentState = EnvironmentState.FAILED;
      this.environmentErrorCode = ERR_ENVIRONMENT_INITIALIZATION_FAILED;
      this.environmentErrorMessage = 'Renderer not available';
      return {
        success: false,
        error: { code: ERR_ENVIRONMENT_INITIALIZATION_FAILED, message: 'Renderer not available' }
      };
    }

    this.environmentState = EnvironmentState.INITIALIZING;

    try {
      // 1. 创建 PMREMGenerator
      this.pmremGenerator = new THREE.PMREMGenerator(this.renderer);

      // 2. 构建程序化环境场景
      var envScene = this._buildProgrammaticEnvironmentScene();

      // 3. 生成 PMREM 纹理
      //    fromScene(scene, sigma=0, near=0.1, far=100)
      //    sigma=0:无模糊,保留场景原始亮度
      this.environmentRenderTarget = this.pmremGenerator.fromScene(envScene, 0, 0.1, 100);
      this.environmentTexture = this.environmentRenderTarget.texture;

      // 4. 释放程序化环境场景(PMREM 已烘焙,不再需要源场景)
      this._disposeProgrammaticEnvironmentScene(envScene);

      // 5. 设置环境来源
      this.environmentSource = ENVIRONMENT_SOURCE_ROOM;

      // 6. 设置默认状态(不自动启用)
      this.environmentEnabled = false;
      this.skyboxVisible = false;
      this.environmentIntensity = ENVIRONMENT_INTENSITY_DEFAULT;

      // 7. 设置 scene.environmentIntensity(three.module.js 支持)
      if (this.scene) {
        this.scene.environmentIntensity = this.environmentIntensity;
      }

      this.environmentState = EnvironmentState.READY;
      return { success: true, state: this.environmentState };
    } catch (e) {
      var msg = e && e.message ? e.message : String(e);
      this.environmentState = EnvironmentState.FAILED;
      this.environmentErrorCode = ERR_ENVIRONMENT_INITIALIZATION_FAILED;
      this.environmentErrorMessage = msg;
      // 清理已分配但失败的环境资源
      this._disposeEnvironmentResources();
      return {
        success: false,
        error: { code: ERR_ENVIRONMENT_INITIALIZATION_FAILED, message: msg }
      };
    }
  }

  /**
   * Phase 2F: 启用/禁用环境光照。
   *
   * 启用:
   *   - scene.environment = environmentTexture
   *   - environmentEnabled = true
   *
   * 禁用:
   *   - scene.environment = null
   *   - environmentEnabled = false
   *   - 如果 skyboxVisible 为 true,自动关闭天空盒(避免无效组合)
   *   - 恢复 scene.background 为保存的纯色背景
   *
   * @param {boolean} enabled
   * @returns {{success: boolean, enabled?: boolean, error?: {code: string, message: string}}}
   */
  setEnvironmentEnabled(enabled) {
    if (this._disposed) {
      return {
        success: false,
        error: { code: ERR_ENVIRONMENT_DISPOSED, message: 'Scene disposed' }
      };
    }
    if (typeof enabled !== 'boolean') {
      return {
        success: false,
        error: { code: ERR_ENVIRONMENT_ENABLED_INVALID, message: 'enabled must be a boolean' }
      };
    }
    if (this.environmentState !== EnvironmentState.READY) {
      return {
        success: false,
        error: { code: ERR_ENVIRONMENT_NOT_READY, message: 'Environment state is ' + this.environmentState + ', expected READY' }
      };
    }
    if (!this.environmentTexture) {
      return {
        success: false,
        error: { code: ERR_ENVIRONMENT_TEXTURE_MISSING, message: 'Environment texture not generated' }
      };
    }
    if (!this.scene) {
      return {
        success: false,
        error: { code: SCENE_INITIALIZATION_FAILED, message: 'Scene not initialized' }
      };
    }

    if (enabled) {
      this.scene.environment = this.environmentTexture;
      this.environmentEnabled = true;
    } else {
      // 禁用环境:先关闭天空盒(如果开启)
      if (this.skyboxVisible) {
        this._restoreSavedBackground();
        this.skyboxVisible = false;
      }
      this.scene.environment = null;
      this.environmentEnabled = false;
    }
    return { success: true, enabled: this.environmentEnabled };
  }

  /**
   * Phase 2F: 显示/隐藏天空盒。
   *
   * 显示天空盒的条件:
   *   - environmentState === READY
   *   - environmentEnabled === true
   *   - environmentTexture != null
   *
   * 显示:
   *   - 保存当前 scene.background (THREE.Color) 到 _savedBackgroundColor
   *   - scene.background = environmentTexture
   *   - skyboxVisible = true
   *
   * 隐藏:
   *   - 恢复 scene.background 为保存的纯色背景
   *   - skyboxVisible = false
   *
   * @param {boolean} visible
   * @returns {{success: boolean, visible?: boolean, error?: {code: string, message: string}}}
   */
  setSkyboxVisible(visible) {
    if (this._disposed) {
      return {
        success: false,
        error: { code: ERR_ENVIRONMENT_DISPOSED, message: 'Scene disposed' }
      };
    }
    if (typeof visible !== 'boolean') {
      return {
        success: false,
        error: { code: ERR_SKYBOX_VISIBLE_INVALID, message: 'visible must be a boolean' }
      };
    }
    if (this.environmentState !== EnvironmentState.READY) {
      return {
        success: false,
        error: { code: ERR_ENVIRONMENT_NOT_READY, message: 'Environment state is ' + this.environmentState + ', expected READY' }
      };
    }
    if (!this.environmentEnabled) {
      return {
        success: false,
        error: { code: ERR_ENVIRONMENT_NOT_ENABLED, message: 'Environment not enabled' }
      };
    }
    if (!this.environmentTexture) {
      return {
        success: false,
        error: { code: ERR_ENVIRONMENT_TEXTURE_MISSING, message: 'Environment texture not generated' }
      };
    }
    if (!this.scene) {
      return {
        success: false,
        error: { code: SCENE_INITIALIZATION_FAILED, message: 'Scene not initialized' }
      };
    }

    if (visible) {
      // 保存当前纯色背景(只在首次开启时保存,避免覆盖)
      if (!this._savedBackgroundColor && this.scene.background instanceof THREE.Color) {
        this._savedBackgroundColor = this.scene.background.clone();
      }
      this.scene.background = this.environmentTexture;
      this.skyboxVisible = true;
    } else {
      this._restoreSavedBackground();
      this.skyboxVisible = false;
    }
    return { success: true, visible: this.skyboxVisible };
  }

  /**
   * Phase 2F: 设置环境强度。
   *
   * 使用 scene.environmentIntensity (three.module.js 支持,见 line 17121)。
   *
   * 范围:0.0 ~ 2.0
   * 默认:1.0
   *
   * @param {number} intensity 0.0 ~ 2.0
   * @returns {{success: boolean, intensity?: number, error?: {code: string, message: string}}}
   */
  setEnvironmentIntensity(intensity) {
    if (this._disposed) {
      return {
        success: false,
        error: { code: ERR_ENVIRONMENT_DISPOSED, message: 'Scene disposed' }
      };
    }
    if (typeof intensity !== 'number' || isNaN(intensity) || !isFinite(intensity)) {
      return {
        success: false,
        error: { code: ERR_ENVIRONMENT_INTENSITY_INVALID, message: 'intensity must be a finite number' }
      };
    }
    if (intensity < ENVIRONMENT_INTENSITY_MIN || intensity > ENVIRONMENT_INTENSITY_MAX) {
      return {
        success: false,
        error: {
          code: ERR_ENVIRONMENT_INTENSITY_INVALID,
          message: 'intensity must be in range [' + ENVIRONMENT_INTENSITY_MIN + ', ' + ENVIRONMENT_INTENSITY_MAX + ']'
        }
      };
    }
    if (!this.scene) {
      return {
        success: false,
        error: { code: SCENE_INITIALIZATION_FAILED, message: 'Scene not initialized' }
      };
    }

    // three.module.js 支持 scene.environmentIntensity (line 17121)
    this.scene.environmentIntensity = intensity;
    this.environmentIntensity = intensity;
    return { success: true, intensity: this.environmentIntensity };
  }

  /**
   * Phase 2F: 恢复保存的纯色背景。
   *
   * Skybox 关闭时调用,恢复 scene.background 为保存的 THREE.Color。
   * 如果没有保存的背景,使用当前 backgroundColor 创建新的 Color。
   */
  _restoreSavedBackground() {
    if (!this.scene) return;
    if (this._savedBackgroundColor) {
      this.scene.background = this._savedBackgroundColor.clone();
    } else {
      // 没有保存的背景,使用当前 backgroundColor
      this.scene.background = new THREE.Color(this.backgroundColor);
    }
  }

  /**
   * Phase 2F: 获取环境设置快照。
   *
   * @returns {{success: boolean, settings?: object, error?: {code: string, message: string}}}
   */
  getEnvironmentSettings() {
    if (this._disposed) {
      return {
        success: false,
        error: { code: ERR_ENVIRONMENT_DISPOSED, message: 'Scene disposed' }
      };
    }
    return {
      success: true,
      settings: {
        state: this.environmentState,
        source: this.environmentSource,
        environmentEnabled: this.environmentEnabled,
        skyboxVisible: this.skyboxVisible,
        environmentIntensity: this.environmentIntensity,
        backgroundColor: this.backgroundColor,
        errorCode: this.environmentErrorCode,
        errorMessage: this.environmentErrorMessage
      }
    };
  }

  /**
   * Phase 2F: 释放环境相关 GPU 资源。
   *
   * 顺序:
   *   1. scene.environment = null
   *   2. 如果 scene.background 指向环境纹理,恢复纯色背景
   *   3. environmentRenderTarget.dispose()
   *   4. pmremGenerator.dispose()
   *   5. environmentTexture = null (不单独 dispose,由 renderTarget 拥有)
   *
   * 不得:
   *   - 重复释放同一纹理
   *   - dispose 当前纯色背景
   */
  _disposeEnvironmentResources() {
    if (this.scene) {
      this.scene.environment = null;
      // 如果 background 指向环境纹理,恢复纯色背景
      if (this.scene.background === this.environmentTexture) {
        this._restoreSavedBackground();
      }
      // 清除 environmentIntensity
      if ('environmentIntensity' in this.scene) {
        this.scene.environmentIntensity = 1.0;
      }
    }

    if (this.environmentRenderTarget) {
      try { this.environmentRenderTarget.dispose(); } catch (e) { /* ignore */ }
      this.environmentRenderTarget = null;
    }
    // environmentTexture 由 environmentRenderTarget 拥有,不单独 dispose
    this.environmentTexture = null;

    if (this.pmremGenerator) {
      try { this.pmremGenerator.dispose(); } catch (e) { /* ignore */ }
      this.pmremGenerator = null;
    }

    this._savedBackgroundColor = null;
  }

  dispose() {
    if (this._disposed) return;
    this._disposed = true;

    // 1. 释放测试物体(Geometry / Material)
    if (this.testObject) {
      disposeObject3D(this.testObject);
      if (this.scene) this.scene.remove(this.testObject);
      this.testObject = null;
    }

    // Phase 2A-1: 释放 GridHelper(geometry + material)
    if (this.gridHelper) {
      if (this.gridHelper.geometry && typeof this.gridHelper.geometry.dispose === 'function') {
        try { this.gridHelper.geometry.dispose(); } catch (e) { /* ignore */ }
      }
      if (this.gridHelper.material) {
        if (Array.isArray(this.gridHelper.material)) {
          this.gridHelper.material.forEach(function (m) {
            if (m && typeof m.dispose === 'function') {
              try { m.dispose(); } catch (e) { /* ignore */ }
            }
          });
        } else if (typeof this.gridHelper.material.dispose === 'function') {
          try { this.gridHelper.material.dispose(); } catch (e) { /* ignore */ }
        }
      }
      if (this.scene) this.scene.remove(this.gridHelper);
      this.gridHelper = null;
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

    // Phase 2F: 释放环境资源(PMREM / 环境纹理 / 恢复背景)
    // 必须在 renderer 释放前调用(_disposeEnvironmentResources 需要 renderer 上下文)
    this._disposeEnvironmentResources();
    this.environmentState = EnvironmentState.DISPOSED;

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
