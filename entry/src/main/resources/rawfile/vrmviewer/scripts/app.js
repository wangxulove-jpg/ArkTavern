/**
 * App 入口 — Viewer 生命周期与状态机(Phase 1B)
 *
 * 职责:
 *   - 查找 DOM 容器(ViewerStage)
 *   - 创建 ViewerCore 实例
 *   - 注册 ArkTavern Viewer Bridge(委托给 ViewerCore)
 *   - 响应页面生命周期(DOMContentLoaded → initialize)
 *   - 更新占位 UI 与错误覆盖层
 *
 * 不做的事:
 *   - 不直接创建 WebGLRenderer / Scene / Camera(由 ViewerScene / ViewerCamera 负责)
 *   - 不直接调用 network / storage 模块
 *   - 不堆积 Three.js 细节
 *
 * Reference:
 *   - figure-main/index.html: IIFE 中初始化 + animate,本实现拆分为 ViewerCore
 *   - AGENTS.md Phase 1B §九 更新 app.js 推荐结构
 *
 * 与 Figure 的差异:
 *   - Figure 在 IIFE 中同步 initThree + animate,本实现通过 ViewerCore 异步 initialize
 *   - Figure 不显式管理 Bridge,本实现将 Bridge API 委托给 ViewerCore 实例
 *
 * Phase 1B 限制:
 *   - 不加载 VRM(由 Phase 1C 引入)
 *   - 不响应文件导入(由 Phase 1D 引入)
 */
import { ViewerCore } from './viewer/ViewerCore.js';
import { ViewerModelResourceProbe } from './viewer/ViewerModelResourceProbe.js';
import { ViewerUserModelLoadCoordinator } from './viewer/ViewerUserModelLoadCoordinator.js';

(function (global) {
  'use strict';

  /** 创建 ViewerCore 实例并暴露到 window,供 Bridge 委托与调试使用 */
  var viewer = new ViewerCore();
  global.arkTavernViewer = viewer;

  // ===== Phase 1D-2B-1: 资源探测器 =====
  // 不放进 ViewerCore:本阶段探测属于 Bridge/资源传输层,尚未进入模型加载层。
  // 通过 window.arkTavernModelResourceProbe 暴露,供调试与 Bridge 委托使用。
  var modelResourceProbe = new ViewerModelResourceProbe();
  global.arkTavernModelResourceProbe = modelResourceProbe;

  // ===== Phase 1D-2B-2: 用户模型加载协调器 =====
  // 不放进 ViewerCore:协调器属于 Bridge 层,负责前置条件检查与状态机管理。
  // 实际加载由 ViewerCore.loadUserModelResource 委托 ViewerModelLoader.loadModel 完成。
  // 通过 window.arkTavernUserModelLoadCoordinator 暴露,供 Bridge 委托使用。
  var userModelLoadCoordinator = new ViewerUserModelLoadCoordinator({
    viewer: viewer
  });
  global.arkTavernUserModelLoadCoordinator = userModelLoadCoordinator;

  // ===== 占位 UI 更新 =====

  /**
   * 更新占位 UI 的状态文本。
   * Phase 1A 遗留逻辑,Phase 1B 保留用于初始化前的状态显示。
   */
  function updatePlaceholder(state, detail) {
    var statusEl = document.getElementById('ViewerStatusText');
    var detailEl = document.getElementById('ViewerDetailText');
    if (statusEl) {
      statusEl.textContent = state || 'UNKNOWN';
    }
    if (detailEl && detail) {
      detailEl.textContent = detail;
    }
  }

  /** 隐藏占位 UI(Scene 挂载后 canvas 已可见) */
  function hidePlaceholder() {
    var placeholder = document.getElementById('ViewerPlaceholder');
    if (placeholder) {
      placeholder.style.display = 'none';
    }
  }

  /** 显示错误覆盖层 */
  function showErrorOverlay(message) {
    var overlay = document.getElementById('ViewerErrorOverlay');
    var summary = document.getElementById('ViewerErrorSummary');
    if (overlay) {
      overlay.style.display = 'block';
    }
    if (summary) {
      summary.textContent = message || '未知错误';
    }
  }

  // ===== Bridge 委托 =====
  // ViewerBridge.js 已在普通脚本中注册 window.arkTavernViewerBridge(Phase 1A 占位实现)。
  // Phase 1B 在此覆盖为委托给 ViewerCore 的实现,保持 ArkTS 调用接口兼容。
  //
  // ArkTS 通过 runJavaScript('window.arkTavernViewerBridge.<method>()') 调用,
  // 返回值约定为 JSON 字符串:
  //   成功:{"success": true, "state": "READY", ...}
  //   失败:{"success": false, "error": {"code": "...", "phase": "...", "message": "...", "recoverable": false}}

  function jsonResult(obj) {
    try {
      return JSON.stringify(obj);
    } catch (e) {
      return JSON.stringify({ success: false, error: { code: 'JSON_SERIALIZE_FAILED', message: String(e) } });
    }
  }

  /**
   * 调用 ViewerCore 方法并包装为 JSON 结果。
   * @param {function} fn 接收 viewer 实例,返回 {success, state?, error?, ...}
   */
  function callViewer(fn) {
    try {
      var result = fn(viewer);
      return jsonResult(result);
    } catch (e) {
      var msg = e && e.message ? e.message : String(e);
      return jsonResult({
        success: false,
        error: {
          code: 'BRIDGE_CALL_FAILED',
          phase: viewer.getState(),
          message: msg,
          recoverable: false
        }
      });
    }
  }

  global.arkTavernViewerBridge = {
    /**
     * 初始化 Viewer。
     * Phase 1B:DOMContentLoaded 已自动触发初始化,此方法:
     *   - 若已 READY,返回当前状态
     *   - 若已 DISPOSED,返回错误
     *   - 若仍在 INITIALIZING,返回当前状态(允许 ArkTS 轮询)
     *   - 若 FAILED,返回错误(允许 ArkTS 重试触发)
     *   - 若 UNINITIALIZED 且未启动,触发初始化
     */
    initializeViewer: function () {
      return callViewer(function (v) {
        var state = v.getState();
        if (state === 'READY' || state === 'INITIALIZING') {
          return { success: true, state: state };
        }
        if (state === 'DISPOSED') {
          return {
            success: false,
            error: { code: 'VIEWER_ALREADY_DISPOSED', phase: state, message: 'Viewer already disposed', recoverable: false }
          };
        }
        if (state === 'FAILED') {
          return {
            success: false,
            error: { code: 'INIT_FAILED', phase: state, message: 'Viewer previously failed', recoverable: true }
          };
        }
        // UNINITIALIZED:触发初始化
        var container = document.getElementById('ViewerStage');
        if (!container) {
          return {
            success: false,
            error: { code: 'SCENE_INITIALIZATION_FAILED', phase: state, message: 'ViewerStage container not found', recoverable: false }
          };
        }
        // 异步触发,不等待(状态由 onViewerReady 回调推进)
        v.initialize(container).then(function (res) {
          if (res.success) {
            hidePlaceholder();
          }
        });
        return { success: true, state: 'INITIALIZING' };
      });
    },

    /** 销毁 Viewer */
    disposeViewer: function () {
      return callViewer(function (v) {
        v.dispose();
        return { success: true, state: v.getState() };
      });
    },

    /** 获取 Viewer 状态 */
    getViewerState: function () {
      return callViewer(function (v) {
        return {
          state: v.getState(),
          detail: '',
          phase: 'PHASE_1B'
        };
      });
    },

    /** 重置相机到默认位置 */
    resetCamera: function () {
      return callViewer(function (v) {
        v.resetCamera();
        return { success: true, state: v.getState() };
      });
    },

    /** 调整 Viewer 尺寸(ArkTS 主动通知容器尺寸变化时调用) */
    resizeViewer: function (width, height) {
      return callViewer(function (v) {
        var w = Number(width);
        var h = Number(height);
        if (!isFinite(w) || !isFinite(h) || w <= 0 || h <= 0) {
          return {
            success: false,
            error: { code: 'INVALID_SIZE', phase: v.getState(), message: 'width/height must be positive numbers', recoverable: true }
          };
        }
        v.resize(w, h);
        return { success: true, state: v.getState() };
      });
    },

    /** 获取场景详细状态(供调试 Tab 使用) */
    getSceneState: function () {
      return callViewer(function (v) {
        return { success: true, state: v.getState(), scene: v.getSceneState() };
      });
    },

    // ===== Phase 1D-2A: 缓存模型资源协议骨架(不触发加载) =====
    // 委托 window.ViewerBridge.preparedResource keeper,仅保存元数据。
    // 严禁调用 viewer.loadModel() / viewer.replaceModel() / GLTFLoader.load()。
    // 实际加载由 Phase 1D-2B 实现。

    /**
     * 准备模型资源(仅保存元数据,不加载)。
     * @param {string} resourceJson ArkTS 传入的 JSON 字符串
     *   必需字段:resourceUrl / displayName / mimeType / size / extension
     *   禁止字段:cachePath / sourceUri(keeper 会自动过滤)
     * @returns {string} JSON 结果
     *   成功:{"success": true, "state": "RESOURCE_READY"}
     *   失败:{"success": false, "error": {"code": "...", "message": "..."}}
     */
    prepareModelResource: function (resourceJson) {
      var keeper = global.ViewerBridge && global.ViewerBridge.preparedResource;
      if (!keeper || typeof keeper.prepare !== 'function') {
        return jsonResult({
          success: false,
          error: { code: 'KEEPER_UNAVAILABLE', message: 'ViewerBridge.preparedResource keeper not registered' }
        });
      }
      // Phase 1D-2B-2:用户模型加载进行中时禁止替换 PreparedResource
      if (userModelLoadCoordinator && userModelLoadCoordinator.isLoading()) {
        return jsonResult({
          success: false,
          error: { code: 'MODEL_LOAD_IN_PROGRESS', message: '用户模型正在加载中,无法替换资源' }
        });
      }
      try {
        var result = keeper.prepare(resourceJson);
        // Phase 1D-2B-1:资源被替换时清除探测状态
        if (modelResourceProbe) {
          modelResourceProbe.clear();
        }
        // Phase 1D-2B-2:资源被替换时清除加载结果(不影响已加载模型)
        if (userModelLoadCoordinator) {
          userModelLoadCoordinator.clear();
        }
        return result;
      } catch (e) {
        var msg = e && e.message ? e.message : String(e);
        return jsonResult({
          success: false,
          error: { code: 'KEEPER_CALL_FAILED', message: msg }
        });
      }
    },

    /**
     * 获取当前已准备的模型资源。
     * @returns {string} JSON 结果
     *   {"success": true, "resource": <object|null>}
     */
    getPreparedModelResource: function () {
      var keeper = global.ViewerBridge && global.ViewerBridge.preparedResource;
      if (!keeper || typeof keeper.get !== 'function') {
        return jsonResult({
          success: false,
          error: { code: 'KEEPER_UNAVAILABLE', message: 'ViewerBridge.preparedResource keeper not registered' }
        });
      }
      try {
        return keeper.get();
      } catch (e) {
        var msg = e && e.message ? e.message : String(e);
        return jsonResult({
          success: false,
          error: { code: 'KEEPER_CALL_FAILED', message: msg }
        });
      }
    },

    /**
     * 清除已准备的模型资源(不影响已加载模型,本阶段无已加载模型)。
     * @returns {string} JSON 结果
     *   {"success": true, "state": "RESOURCE_CLEARED"}
     */
    clearPreparedModelResource: function () {
      var keeper = global.ViewerBridge && global.ViewerBridge.preparedResource;
      if (!keeper || typeof keeper.clear !== 'function') {
        return jsonResult({
          success: false,
          error: { code: 'KEEPER_UNAVAILABLE', message: 'ViewerBridge.preparedResource keeper not registered' }
        });
      }
      // Phase 1D-2B-2:用户模型加载进行中时禁止清除 PreparedResource
      if (userModelLoadCoordinator && userModelLoadCoordinator.isLoading()) {
        return jsonResult({
          success: false,
          error: { code: 'MODEL_LOAD_IN_PROGRESS', message: '用户模型正在加载中,无法清除资源' }
        });
      }
      try {
        var result = keeper.clear();
        // Phase 1D-2B-1:资源被清除时清除探测状态
        if (modelResourceProbe) {
          modelResourceProbe.clear();
        }
        // Phase 1D-2B-2:资源被清除时清除加载结果(不影响已加载模型)
        if (userModelLoadCoordinator) {
          userModelLoadCoordinator.clear();
        }
        return result;
      } catch (e) {
        var msg = e && e.message ? e.message : String(e);
        return jsonResult({
          success: false,
          error: { code: 'KEEPER_CALL_FAILED', message: msg }
        });
      }
    },

    // ===== Phase 1D-2B-1: 资源探测(HEAD 请求校验,不读取模型文件) =====
    // 委托 window.arkTavernModelResourceProbe 实例。
    // 严格不调用 GLTFLoader.load() / ViewerModelLoader.loadModel() / response.arrayBuffer()。
    //
    // 异步模型说明:
    // ArkWeb 的 runJavaScript 通常不等待 JavaScript Promise,因此 probePreparedModelResource
    // 采用"同步启动 + 异步轮询"模式:
    // 1. probePreparedModelResource() 同步启动探测,立即返回 {"success": true, "state": "PROBING"}
    // 2. 探测异步进行,结果保存在 probe.lastResult 中
    // 3. ArkTS 端通过 getModelResourceProbeResult() 轮询获取最终结果(VERIFIED / FAILED)

    /**
     * 探测已准备的模型资源(HEAD 请求)。
     *
     * 同步启动探测任务,立即返回当前状态。最终结果通过 getModelResourceProbeResult() 获取。
     *
     * @returns {string} JSON 结果
     *   启动成功:{"success": true, "state": "PROBING", "message": "Probe started"}
     *   启动失败:{"success": false, "error": {"code": "...", "message": "..."}}
     */
    probePreparedModelResource: function () {
      var probe = global.arkTavernModelResourceProbe;
      if (!probe || typeof probe.probe !== 'function') {
        return jsonResult({
          success: false,
          error: { code: 'PROBE_UNAVAILABLE', message: 'arkTavernModelResourceProbe not registered' }
        });
      }
      // 从 keeper 获取已准备的资源
      var keeper = global.ViewerBridge && global.ViewerBridge.preparedResource;
      if (!keeper || typeof keeper.get !== 'function') {
        return jsonResult({
          success: false,
          error: { code: 'KEEPER_UNAVAILABLE', message: 'preparedResource keeper not registered' }
        });
      }
      var getResourceJson = keeper.get();
      var parsed;
      try {
        parsed = JSON.parse(getResourceJson);
      } catch (e) {
        return jsonResult({
          success: false,
          error: { code: 'KEEPER_RESULT_INVALID', message: 'keeper.get() returned invalid JSON' }
        });
      }
      if (!parsed.success || !parsed.resource) {
        return jsonResult({
          success: false,
          error: { code: 'RESOURCE_NOT_PREPARED', message: 'No prepared model resource' }
        });
      }
      var resource = parsed.resource;

      // 同步启动探测任务(不返回 Promise)
      // 探测结果会异步写入 probe.lastResult,ArkTS 端通过 getModelResourceProbeResult 轮询
      try {
        probe.probe(resource).catch(function (e) {
          // probe() 内部已捕获所有异常并写入 lastResult,这里仅兜底
          var msg = e && e.message ? e.message : String(e);
          console.error('[App] probePreparedModelResource async failed: ' + msg);
        });
      } catch (e) {
        var msg = e && e.message ? e.message : String(e);
        return jsonResult({
          success: false,
          error: { code: 'PROBE_CALL_FAILED', message: msg }
        });
      }

      // 同步返回 PROBING 状态(此时 probe.state 已被 probe.probe() 设为 PROBING)
      return jsonResult({
        success: true,
        state: probe.getState(),
        message: 'Probe started, poll getModelResourceProbeResult for final result'
      });
    },

    /**
     * 获取最近一次探测结果(同步)。
     * @returns {string} JSON 结果
     *   {"success": true, "result": <ModelResourceProbeResult|null>}
     */
    getModelResourceProbeResult: function () {
      var probe = global.arkTavernModelResourceProbe;
      if (!probe || typeof probe.getLastResult !== 'function') {
        return jsonResult({
          success: false,
          error: { code: 'PROBE_UNAVAILABLE', message: 'arkTavernModelResourceProbe not registered' }
        });
      }
      try {
        var result = probe.getLastResult();
        return jsonResult({ success: true, result: result });
      } catch (e) {
        var msg = e && e.message ? e.message : String(e);
        return jsonResult({
          success: false,
          error: { code: 'PROBE_CALL_FAILED', message: msg }
        });
      }
    },

    /**
     * 清除探测状态(资源被替换 / 清除时由 keeper 方法自动调用)。
     * @returns {string} JSON 结果
     *   {"success": true, "state": "PROBE_CLEARED"}
     */
    clearModelResourceProbe: function () {
      var probe = global.arkTavernModelResourceProbe;
      if (!probe || typeof probe.clear !== 'function') {
        return jsonResult({
          success: false,
          error: { code: 'PROBE_UNAVAILABLE', message: 'arkTavernModelResourceProbe not registered' }
        });
      }
      try {
        probe.clear();
        return jsonResult({ success: true, state: 'PROBE_CLEARED' });
      } catch (e) {
        var msg = e && e.message ? e.message : String(e);
        return jsonResult({
          success: false,
          error: { code: 'PROBE_CALL_FAILED', message: msg }
        });
      }
    },

    // ===== Phase 1D-2B-2: 用户模型加载(GLTFLoader 实际加载与原子替换) =====
    // 委托 window.arkTavernUserModelLoadCoordinator 实例。
    // 严格不直接调用 GLTFLoader.load()(由 ViewerCore.loadUserModelResource 委托)。
    // 严格不直接接受外部 URL 参数(只从 PreparedModelResourceKeeper + 探测结果读取)。
    //
    // 异步模型说明(AGENTS.md Phase 1D-2B-2 §十):
    // ArkWeb 的 runJavaScript 不应依赖 JavaScript Promise 返回值,因此:
    // 1. loadPreparedModelResource() 同步启动加载,立即返回 {"success": true, "state": "LOADING"}
    // 2. 加载异步进行,结果保存在 coordinator.lastResult 中
    // 3. ArkTS 端通过 getPreparedModelLoadResult() 轮询获取最终结果(READY / FAILED)

    /**
     * 启动用户模型加载。
     *
     * 从 PreparedModelResourceKeeper 读取已准备的资源,结合探测结果,
     * 调用 Coordinator.start() 同步启动异步加载。立即返回 LOADING 状态。
     * 最终结果通过 getPreparedModelLoadResult() 轮询获取。
     *
     * 严格不:
     * - 不接受外部 URL 参数
     * - 不直接调用 GLTFLoader.load()
     * - 不直接调用 fetch / arrayBuffer / blob
     *
     * @returns {string} JSON 结果
     *   启动成功:{"success": true, "state": "LOADING", "message": "..."}
     *   启动失败:{"success": false, "error": {"code": "...", "message": "..."}}
     */
    loadPreparedModelResource: function () {
      var coordinator = global.arkTavernUserModelLoadCoordinator;
      if (!coordinator || typeof coordinator.start !== 'function') {
        return jsonResult({
          success: false,
          error: { code: 'COORDINATOR_UNAVAILABLE', message: 'arkTavernUserModelLoadCoordinator not registered' }
        });
      }
      // 从 keeper 获取已准备的资源
      var keeper = global.ViewerBridge && global.ViewerBridge.preparedResource;
      if (!keeper || typeof keeper.get !== 'function') {
        return jsonResult({
          success: false,
          error: { code: 'KEEPER_UNAVAILABLE', message: 'preparedResource keeper not registered' }
        });
      }
      var getResourceJson = keeper.get();
      var parsed;
      try {
        parsed = JSON.parse(getResourceJson);
      } catch (e) {
        return jsonResult({
          success: false,
          error: { code: 'KEEPER_RESULT_INVALID', message: 'keeper.get() returned invalid JSON' }
        });
      }
      if (!parsed.success || !parsed.resource) {
        return jsonResult({
          success: false,
          error: { code: 'RESOURCE_NOT_PREPARED', message: 'No prepared model resource' }
        });
      }
      var resource = parsed.resource;

      // 获取探测结果
      var probe = global.arkTavernModelResourceProbe;
      if (!probe || typeof probe.getLastResult !== 'function') {
        return jsonResult({
          success: false,
          error: { code: 'PROBE_UNAVAILABLE', message: 'arkTavernModelResourceProbe not registered' }
        });
      }
      var probeResult = probe.getLastResult();

      // 启动加载(同步返回 LOADING 或 FAILED 结果)
      try {
        var result = coordinator.start(resource, probeResult);
        return jsonResult({
          success: true,
          state: result.state,
          message: 'Load started, poll getPreparedModelLoadResult for final result'
        });
      } catch (e) {
        var msg = e && e.message ? e.message : String(e);
        return jsonResult({
          success: false,
          error: { code: 'LOAD_START_FAILED', message: msg }
        });
      }
    },

    /**
     * 获取最近一次用户模型加载结果(同步)。
     *
     * @returns {string} JSON 结果
     *   {"success": true, "result": <UserModelLoadResult|null>}
     *   result.state 为 NOT_REQUESTED / LOADING / READY / FAILED / DISPOSED
     *   result 不含 cachePath / sourceUri / 文件描述符
     */
    getPreparedModelLoadResult: function () {
      var coordinator = global.arkTavernUserModelLoadCoordinator;
      if (!coordinator || typeof coordinator.getLastResult !== 'function') {
        return jsonResult({
          success: false,
          error: { code: 'COORDINATOR_UNAVAILABLE', message: 'arkTavernUserModelLoadCoordinator not registered' }
        });
      }
      try {
        var result = coordinator.getLastResult();
        return jsonResult({ success: true, result: result });
      } catch (e) {
        var msg = e && e.message ? e.message : String(e);
        return jsonResult({
          success: false,
          error: { code: 'COORDINATOR_CALL_FAILED', message: msg }
        });
      }
    },

    /**
     * 清除用户模型加载结果(不影响已加载模型)。
     *
     * - 重置 coordinator.state 为 NOT_REQUESTED
     * - 清空 coordinator.lastResult
     * - 不影响已加载到 Viewer 的模型
     * - 不取消正在进行的加载(其结果会因代次检查被忽略)
     *
     * @returns {string} JSON 结果
     *   {"success": true, "state": "LOAD_RESULT_CLEARED"}
     */
    clearPreparedModelLoadResult: function () {
      var coordinator = global.arkTavernUserModelLoadCoordinator;
      if (!coordinator || typeof coordinator.clear !== 'function') {
        return jsonResult({
          success: false,
          error: { code: 'COORDINATOR_UNAVAILABLE', message: 'arkTavernUserModelLoadCoordinator not registered' }
        });
      }
      try {
        coordinator.clear();
        return jsonResult({ success: true, state: 'LOAD_RESULT_CLEARED' });
      } catch (e) {
        var msg = e && e.message ? e.message : String(e);
        return jsonResult({
          success: false,
          error: { code: 'COORDINATOR_CALL_FAILED', message: msg }
        });
      }
    }
  };

  console.log('[App] arkTavernViewerBridge registered (Phase 1B + 1D-2A + 1D-2B-1 + 1D-2B-2, delegates to ViewerCore + preparedResource keeper + probe + userModelLoadCoordinator)');

  // ===== 页面生命周期 =====

  /**
   * DOM 就绪后启动 ViewerCore.initialize。
   * ViewerCore 内部会创建 Scene / Camera / FrameLoop,并通过 ViewerBridge 通知 ArkTS。
   */
  async function onDomReady() {
    updatePlaceholder('INITIALIZING', '正在初始化 Three.js Scene...');
    var container = document.getElementById('ViewerStage');
    if (!container) {
      var msg = 'ViewerStage container not found';
      updatePlaceholder('FAILED', msg);
      showErrorOverlay(msg);
      console.error('[App] ' + msg);
      return;
    }
    try {
      var result = await viewer.initialize(container);
      if (result.success) {
        hidePlaceholder();
        updatePlaceholder('READY', 'Viewer 就绪');
        console.log('[App] ViewerCore initialized, state=' + result.state);
      } else {
        var errMsg = (result.error && result.error.message) ? result.error.message : 'unknown error';
        var errCode = (result.error && result.error.code) ? result.error.code : 'UNKNOWN';
        updatePlaceholder('FAILED', errCode + ': ' + errMsg);
        showErrorOverlay(errCode + '\n' + errMsg);
        console.error('[App] ViewerCore init failed: ' + errCode + ' ' + errMsg);
      }
    } catch (e) {
      var eMsg = e && e.message ? e.message : String(e);
      updatePlaceholder('FAILED', eMsg);
      showErrorOverlay(eMsg);
      console.error('[App] ViewerCore initialize threw: ' + eMsg);
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', function () {
      onDomReady();
    });
  } else {
    onDomReady();
  }
})(typeof window !== 'undefined' ? window : globalThis);
