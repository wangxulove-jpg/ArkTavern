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

// Phase 1D-2C-2C: 标记 app.js 模块主体开始执行
// (静态 import 已完成,若 import 失败此行不会执行,
//  bootstrap.js 的 window.error / unhandledrejection 监听负责捕获)
if (window.__arkTavernBootstrapState) {
  window.__arkTavernBootstrapState.markModuleExecuting();
}

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
  // Phase 1D-2C-1:注入 onDiagnostic 回调,转发到 arkTavernVrmRuntimeDiagnostics keeper。
  var userModelLoadCoordinator = new ViewerUserModelLoadCoordinator({
    viewer: viewer,
    onDiagnostic: function (diagnostic) {
      var keeper = global.arkTavernVrmRuntimeDiagnostics;
      if (keeper && typeof keeper.record === 'function') {
        try {
          keeper.record(diagnostic);
        } catch (e) {
          console.warn('[App] coordinator diagnostic forward failed: ' + (e && e.message ? e.message : String(e)));
        }
      }
    }
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

  // ===== Phase 3E-2: 表情别名与临时表情参数解析 =====

  /**
   * 禁止字段白名单 (与 setExpression 保持一致, 禁止路径相关字段)。
   */
  var EXPRESSION_FORBIDDEN_FIELDS = ['absolutePath', 'relativePath', 'filesDir', 'fileDescriptor', 'sourceUri', 'cachePath'];

  function makeExpressionError(code, message) {
    return { success: false, error: { code: code, message: message } };
  }

  /**
   * 解析 setTemporaryExpression 参数 JSON。
   * 成功返回 { name, weight, durationMs, restorePolicy }
   * 失败返回 { error: <errorObject> }
   */
  function parseTemporaryExpressionParams(paramsJson) {
    if (typeof paramsJson !== 'string' || paramsJson.length === 0) {
      return { error: makeExpressionError('EXPRESSION_NAME_INVALID', 'paramsJson must be a non-empty string') };
    }
    var params;
    try {
      params = JSON.parse(paramsJson);
    } catch (e) {
      return { error: makeExpressionError('EXPRESSION_NAME_INVALID',
        'paramsJson is not valid JSON: ' + (e && e.message ? e.message : String(e))) };
    }
    if (!params || typeof params !== 'object' || Array.isArray(params)) {
      return { error: makeExpressionError('EXPRESSION_NAME_INVALID', 'paramsJson parsed to non-object') };
    }
    for (var i = 0; i < EXPRESSION_FORBIDDEN_FIELDS.length; i++) {
      if (Object.prototype.hasOwnProperty.call(params, EXPRESSION_FORBIDDEN_FIELDS[i])) {
        return { error: makeExpressionError('EXPRESSION_NAME_INVALID',
          'Forbidden field present: ' + EXPRESSION_FORBIDDEN_FIELDS[i]) };
      }
    }
    if (typeof params.name !== 'string' || params.name.length === 0) {
      return { error: makeExpressionError('EXPRESSION_NAME_INVALID', 'params.name must be a non-empty string') };
    }
    if (typeof params.weight !== 'number' || !isFinite(params.weight) || params.weight < 0 || params.weight > 1) {
      return { error: makeExpressionError('EXPRESSION_WEIGHT_INVALID',
        'params.weight must be a finite number in [0, 1]') };
    }
    if (typeof params.durationMs !== 'number' || !isFinite(params.durationMs) ||
        params.durationMs < 100 || params.durationMs > 30000) {
      return { error: makeExpressionError('EXPRESSION_DURATION_INVALID',
        'params.durationMs must be in [100, 30000], got ' + params.durationMs) };
    }
    if (params.restorePolicy !== 'PREVIOUS' && params.restorePolicy !== 'RESET') {
      return { error: makeExpressionError('EXPRESSION_RESTORE_POLICY_INVALID',
        'params.restorePolicy must be PREVIOUS or RESET, got ' + params.restorePolicy) };
    }
    return { name: params.name, weight: params.weight, durationMs: params.durationMs, restorePolicy: params.restorePolicy };
  }

  /**
   * 校验 aliases 字段: 必须是对象 (非数组), key/value 均为非空字符串。
   */
  function validateAliases(aliases) {
    if (aliases === undefined || aliases === null) {
      return {}; // 允许缺失, 视为空映射
    }
    if (typeof aliases !== 'object' || Array.isArray(aliases)) {
      return null; // 非法
    }
    // 过滤为只含 string→string 的对象
    var result = {};
    var keys = Object.keys(aliases);
    for (var i = 0; i < keys.length; i++) {
      var k = keys[i];
      var v = aliases[k];
      if (typeof k === 'string' && k.length > 0 && typeof v === 'string' && v.length > 0) {
        result[k] = v;
      }
    }
    return result;
  }

  /**
   * 解析 setExpressionByAlias 参数 JSON。
   */
  function parseAliasParams(paramsJson) {
    if (typeof paramsJson !== 'string' || paramsJson.length === 0) {
      return { error: makeExpressionError('EXPRESSION_NAME_INVALID', 'paramsJson must be a non-empty string') };
    }
    var params;
    try {
      params = JSON.parse(paramsJson);
    } catch (e) {
      return { error: makeExpressionError('EXPRESSION_NAME_INVALID',
        'paramsJson is not valid JSON: ' + (e && e.message ? e.message : String(e))) };
    }
    if (!params || typeof params !== 'object' || Array.isArray(params)) {
      return { error: makeExpressionError('EXPRESSION_NAME_INVALID', 'paramsJson parsed to non-object') };
    }
    for (var i = 0; i < EXPRESSION_FORBIDDEN_FIELDS.length; i++) {
      if (Object.prototype.hasOwnProperty.call(params, EXPRESSION_FORBIDDEN_FIELDS[i])) {
        return { error: makeExpressionError('EXPRESSION_NAME_INVALID',
          'Forbidden field present: ' + EXPRESSION_FORBIDDEN_FIELDS[i]) };
      }
    }
    if (typeof params.expressionId !== 'string' || params.expressionId.length === 0) {
      return { error: makeExpressionError('EXPRESSION_NAME_INVALID', 'params.expressionId must be a non-empty string') };
    }
    var aliases = validateAliases(params.aliases);
    if (aliases === null) {
      return { error: makeExpressionError('EXPRESSION_NAME_INVALID', 'params.aliases must be an object') };
    }
    if (typeof params.weight !== 'number' || !isFinite(params.weight) || params.weight < 0 || params.weight > 1) {
      return { error: makeExpressionError('EXPRESSION_WEIGHT_INVALID',
        'params.weight must be a finite number in [0, 1]') };
    }
    return { expressionId: params.expressionId, aliases: aliases, weight: params.weight };
  }

  /**
   * 解析 setTemporaryExpressionByAlias 参数 JSON。
   */
  function parseTemporaryAliasParams(paramsJson) {
    var base = parseAliasParams(paramsJson);
    if (base.error) {
      return base;
    }
    // base 已解析 expressionId/aliases/weight, 还需 durationMs/restorePolicy
    var params;
    try {
      params = JSON.parse(paramsJson);
    } catch (e) {
      return { error: makeExpressionError('EXPRESSION_NAME_INVALID', 're-parse failed') };
    }
    if (typeof params.durationMs !== 'number' || !isFinite(params.durationMs) ||
        params.durationMs < 100 || params.durationMs > 30000) {
      return { error: makeExpressionError('EXPRESSION_DURATION_INVALID',
        'params.durationMs must be in [100, 30000], got ' + params.durationMs) };
    }
    if (params.restorePolicy !== 'PREVIOUS' && params.restorePolicy !== 'RESET') {
      return { error: makeExpressionError('EXPRESSION_RESTORE_POLICY_INVALID',
        'params.restorePolicy must be PREVIOUS or RESET, got ' + params.restorePolicy) };
    }
    return {
      expressionId: base.expressionId,
      aliases: base.aliases,
      weight: base.weight,
      durationMs: params.durationMs,
      restorePolicy: params.restorePolicy
    };
  }

  /**
   * 解析 resolveExpressionAlias 参数 JSON。
   */
  function parseResolveAliasParams(paramsJson) {
    if (typeof paramsJson !== 'string' || paramsJson.length === 0) {
      return { error: makeExpressionError('EXPRESSION_NAME_INVALID', 'paramsJson must be a non-empty string') };
    }
    var params;
    try {
      params = JSON.parse(paramsJson);
    } catch (e) {
      return { error: makeExpressionError('EXPRESSION_NAME_INVALID',
        'paramsJson is not valid JSON: ' + (e && e.message ? e.message : String(e))) };
    }
    if (!params || typeof params !== 'object' || Array.isArray(params)) {
      return { error: makeExpressionError('EXPRESSION_NAME_INVALID', 'paramsJson parsed to non-object') };
    }
    for (var i = 0; i < EXPRESSION_FORBIDDEN_FIELDS.length; i++) {
      if (Object.prototype.hasOwnProperty.call(params, EXPRESSION_FORBIDDEN_FIELDS[i])) {
        return { error: makeExpressionError('EXPRESSION_NAME_INVALID',
          'Forbidden field present: ' + EXPRESSION_FORBIDDEN_FIELDS[i]) };
      }
    }
    if (typeof params.expressionId !== 'string' || params.expressionId.length === 0) {
      return { error: makeExpressionError('EXPRESSION_NAME_INVALID', 'params.expressionId must be a non-empty string') };
    }
    var aliases = validateAliases(params.aliases);
    if (aliases === null) {
      return { error: makeExpressionError('EXPRESSION_NAME_INVALID', 'params.aliases must be an object') };
    }
    return { expressionId: params.expressionId, aliases: aliases };
  }

  // ===== Phase 1D-2C-2A: 启动诊断记录 =====
  // 委托 global.arkTavernVrmRuntimeDiagnostics keeper(ViewerBridge.js 注册)。
  // 记录启动链路:ARKWEB_PAGE_END / JS_BRIDGE_BOUND / INITIALIZE_REQUESTED /
  // VIEWER_CONTAINER_FOUND / VIEWER_CONTAINER_NOT_FOUND / VIEWER_CORE_INITIALIZING /
  // VIEWER_READY / VIEWER_INITIALIZE_FAILED。
  //
  // 安全约束:不记录 cachePath / sourceUri / fd / stack / 用户目录。
  function emitStartupDiagnostic(stage, code, message) {
    var keeper = global.arkTavernVrmRuntimeDiagnostics;
    if (!keeper || typeof keeper.record !== 'function') {
      return;
    }
    var msg = String(message || '');
    if (msg.length > 256) {
      msg = msg.substring(0, 256);
    }
    var diagnostic = {
      stage: stage,
      code: code || '',
      message: msg,
      resourceId: '',
      requestMethod: '',
      httpStatus: 0,
      mimeType: '',
      contentLength: 0,
      timestamp: Date.now()
    };
    try {
      keeper.record(diagnostic);
    } catch (e) {
      console.warn('[App] startup diagnostic record failed: ' + (e && e.message ? e.message : String(e)));
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
     *
     * Phase 1D-2C-2A:
     *   - 严格同步返回 JSON 字符串(不声明 async,不返回 Promise)
     *   - 记录启动诊断(INITIALIZE_REQUESTED / VIEWER_CONTAINER_FOUND /
     *     VIEWER_CONTAINER_NOT_FOUND / VIEWER_CORE_INITIALIZING)
     *   - Viewer.initialize() 异步触发,不等待,失败由 onViewerError 回调推进
     */
    initializeViewer: function () {
      // Phase 1D-2C-2A: 记录 INITIALIZE_REQUESTED
      emitStartupDiagnostic('INITIALIZE_REQUESTED', '', 'initializeViewer called');

      return callViewer(function (v) {
        var state = v.getState();
        if (state === 'READY' || state === 'INITIALIZING') {
          // 已 READY 或正在 INITIALIZING:幂等返回,不再次触发 initialize
          return { success: true, state: state };
        }
        if (state === 'DISPOSED') {
          return {
            success: false,
            error: { code: 'VIEWER_ALREADY_DISPOSED', phase: state, message: 'Viewer already disposed', recoverable: false }
          };
        }
        if (state === 'FAILED') {
          // Phase 1D-2C-2A: FAILED 时返回保存的错误,不自动重新初始化
          // 重试需通过 retryInitializeViewer() 显式触发
          return {
            success: false,
            error: { code: 'INIT_FAILED', phase: state, message: 'Viewer previously failed, call retryInitializeViewer to retry', recoverable: true }
          };
        }
        // UNINITIALIZED:触发初始化
        var container = document.getElementById('ViewerStage');
        if (!container) {
          // Phase 1D-2C-2A: 记录 VIEWER_CONTAINER_NOT_FOUND
          emitStartupDiagnostic('VIEWER_CONTAINER_NOT_FOUND', 'VIEWER_CONTAINER_NOT_FOUND', 'ViewerStage container not found');
          return {
            success: false,
            error: { code: 'VIEWER_CONTAINER_NOT_FOUND', phase: state, message: 'ViewerStage container not found', recoverable: false }
          };
        }
        // Phase 1D-2C-2A: 记录 VIEWER_CONTAINER_FOUND
        emitStartupDiagnostic('VIEWER_CONTAINER_FOUND', '', 'ViewerStage container found');

        // Phase 1D-2C-2A: 记录 VIEWER_CORE_INITIALIZING(异步触发,不等待)
        emitStartupDiagnostic('VIEWER_CORE_INITIALIZING', '', 'ViewerCore.initialize started');
        v.initialize(container).then(function (res) {
          if (res.success) {
            hidePlaceholder();
          }
          // 失败时 ViewerCore._notifyError 已通过 onViewerError 回调通知 ArkTS,
          // 此处不重复上报,避免覆盖更具体的错误码。
        }).catch(function (error) {
          // 兜底:ViewerCore.initialize 抛出异常(不应发生,但保护)
          var msg = error && error.message ? error.message : String(error);
          emitStartupDiagnostic('VIEWER_INITIALIZE_FAILED', 'VIEWER_INITIALIZE_REJECTED', 'ViewerCore.initialize rejected: ' + msg);
        });
        return { success: true, state: 'INITIALIZING' };
      });
    },

    /**
     * Phase 1D-2C-2A: 重试 Viewer 初始化。
     *
     * 仅在 Viewer 处于 FAILED 状态时有效。
     * - 重置 ViewerCore 状态(若支持)或重新创建实例
     * - 触发 initialize(container)
     * - 同步返回 INITIALIZING,结果通过 onViewerReady/onViewerError 回调
     *
     * @returns {string} JSON 结果
     *   成功启动:{"success": true, "state": "INITIALIZING"}
     *   当前非 FAILED:{"success": false, "error": {"code": "RETRY_NOT_ALLOWED", ...}}
     */
    retryInitializeViewer: function () {
      emitStartupDiagnostic('INITIALIZE_REQUESTED', '', 'retryInitializeViewer called');
      return callViewer(function (v) {
        var state = v.getState();
        if (state !== 'FAILED') {
          return {
            success: false,
            error: {
              code: 'RETRY_NOT_ALLOWED',
              phase: state,
              message: 'Retry only allowed in FAILED state, current: ' + state,
              recoverable: false
            }
          };
        }
        var container = document.getElementById('ViewerStage');
        if (!container) {
          emitStartupDiagnostic('VIEWER_CONTAINER_NOT_FOUND', 'VIEWER_CONTAINER_NOT_FOUND', 'ViewerStage container not found');
          return {
            success: false,
            error: { code: 'VIEWER_CONTAINER_NOT_FOUND', phase: state, message: 'ViewerStage container not found', recoverable: false }
          };
        }
        emitStartupDiagnostic('VIEWER_CONTAINER_FOUND', '', 'ViewerStage container found for retry');
        emitStartupDiagnostic('VIEWER_CORE_INITIALIZING', '', 'ViewerCore.initialize started (retry)');
        v.initialize(container).then(function (res) {
          if (res.success) {
            hidePlaceholder();
          }
        }).catch(function (error) {
          var msg = error && error.message ? error.message : String(error);
          emitStartupDiagnostic('VIEWER_INITIALIZE_FAILED', 'VIEWER_INITIALIZE_REJECTED', 'Retry rejected: ' + msg);
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

    /**
     * Phase 2A-2: 重置相机到 Figure 基准位置。
     * Figure 基准: FOV=30, near=0.1, far=20, position=(0,1.25,2), target=(0,1.25,0)
     * 不依赖当前模型大小。preserveControlsEnabled 保持控制面板触摸隔离状态。
     */
    resetCamera: function () {
      return callViewer(function (v) {
        var result = v.resetCamera();
        // 规范化返回:确保始终有 success 字段
        if (result && result.success) {
          return { success: true, state: v.getState(), cameraState: result.state };
        }
        return {
          success: false,
          state: v.getState(),
          error: result && result.error ? result.error : { code: 'RESET_FAILED', message: 'resetCamera failed' }
        };
      });
    },

    /**
     * Phase 2A-2: 聚焦到当前已加载模型。
     * 从 ViewerModelLoader.currentVrm 获取真实模型,计算包围盒并调整相机。
     */
    focusCameraOnCurrentModel: function () {
      return callViewer(function (v) {
        var result = v.focusCameraOnCurrentModel({ action: 'FOCUS', preserveControlsEnabled: true });
        if (result && result.success) {
          return { success: true, state: v.getState(), cameraState: result.state, bounds: result.bounds };
        }
        return {
          success: false,
          state: v.getState(),
          error: result && result.error ? result.error : { code: 'FOCUS_FAILED', message: 'focusCameraOnCurrentModel failed' }
        };
      });
    },

    /**
     * Phase 2A-2: 获取当前 Camera 状态(供 Debug Tab 使用)。
     */
    getCameraState: function () {
      return callViewer(function (v) {
        var result = v.getCameraState();
        if (result && result.success) {
          return { success: true, state: v.getState(), cameraState: result.state };
        }
        return {
          success: false,
          state: v.getState(),
          error: result && result.error ? result.error : { code: 'CAMERA_STATE_FAILED', message: 'getCameraState failed' }
        };
      });
    },

    // ===== Phase 2B: 平滑重置 =====

    /**
     * Phase 2B: 平滑重置相机到 Figure 基准位置。
     *
     * 同步启动过渡,由现有帧循环异步驱动完成。不创建第二个 requestAnimationFrame。
     *
     * 终点固定为 Figure 基准(与 resetCamera() 完全一致):
     *   FOV=30, near=0.1, far=20, position=(0,1.25,2), target=(0,1.25,0)
     *
     * 起点为当前真实相机状态。缓动:smootherStep。
     *
     * @param {object} [options] 可选参数
     *   - durationSeconds: 过渡时长(0.1~2.0 秒),默认 0.45
     *   - preserveControlsEnabled: 是否保持 controls.enabled,默认 true
     * @returns {string} JSON 结果
     *   启动成功: {"success": true, "state": "RUNNING", "transition": {...}}
     *   启动失败: {"success": false, "error": {...}, "transition": {...}|undefined}
     */
    smoothResetCamera: function (options) {
      return callViewer(function (v) {
        var opts = options || {};
        // 严格数值校验:durationSeconds 必须为有限数值
        if (opts.durationSeconds !== undefined && typeof opts.durationSeconds !== 'number') {
          return {
            success: false,
            state: v.getState(),
            error: {
              code: 'CAMERA_SMOOTH_RESET_DURATION_INVALID',
              phase: v.getState(),
              message: 'durationSeconds must be a number',
              recoverable: false
            }
          };
        }
        // 严格布尔校验:preserveControlsEnabled 必须为布尔
        if (opts.preserveControlsEnabled !== undefined && typeof opts.preserveControlsEnabled !== 'boolean') {
          return {
            success: false,
            state: v.getState(),
            error: {
              code: 'INVALID_ARGUMENT',
              phase: v.getState(),
              message: 'preserveControlsEnabled must be a boolean',
              recoverable: false
            }
          };
        }
        var result = v.smoothResetCamera(opts);
        if (result && result.success) {
          return {
            success: true,
            state: v.getState(),
            transitionState: result.state,
            transition: result.transition
          };
        }
        return {
          success: false,
          state: v.getState(),
          transitionState: result && result.state ? result.state : undefined,
          transition: result && result.transition ? result.transition : undefined,
          error: result && result.error ? result.error : {
            code: 'SMOOTH_RESET_FAILED',
            phase: v.getState(),
            message: 'smoothResetCamera failed',
            recoverable: false
          }
        };
      });
    },

    /**
     * Phase 2B: 获取当前相机过渡状态。
     *
     * 用于 ArkTS 轮询平滑重置进度。
     *
     * @returns {string} JSON 结果
     *   {"success": true, "state": viewerState, "transition": {...}}
     *   transition.state: IDLE/RUNNING/COMPLETED/CANCELLED/FAILED/DISPOSED
     */
    getCameraTransitionState: function () {
      return callViewer(function (v) {
        var result = v.getCameraTransitionState();
        return {
          success: true,
          state: v.getState(),
          transition: result.transition
        };
      });
    },

    /**
     * Phase 2B: 取消当前平滑相机过渡。
     *
     * 取消后保留取消瞬间的相机位置,不跳到终点,不恢复起点。
     *
     * @param {string} reason 取消原因
     * @returns {string} JSON 结果
     *   {"success": true, "state": viewerState, "transition": {...}}
     */
    cancelCameraTransition: function (reason) {
      return callViewer(function (v) {
        var r = typeof reason === 'string' ? reason : String(reason || 'UNKNOWN');
        var result = v.cancelCameraTransition(r);
        return {
          success: true,
          state: v.getState(),
          transition: result.transition
        };
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

    // ===== Phase 2A-1: Camera Controls enable/disable =====
    // 用于控制面板触摸隔离:ArkUI 控制面板发生触摸时禁用 OrbitControls,
    // 触摸结束或取消时恢复 OrbitControls。

    /**
     * 启用/禁用 OrbitControls。
     * @param {boolean} enabled true=启用;false=禁用
     * @returns {string} JSON 结果
     *   成功:{"success": true, "enabled": true|false}
     *   失败:{"success": false, "error": {"code": "...", "message": "..."}}
     */
    setCameraControlsEnabled: function (enabled) {
      return callViewer(function (v) {
        // 严格布尔校验:拒绝字符串 "true" / 数字 1 / 任意对象
        if (typeof enabled !== 'boolean') {
          return {
            success: false,
            error: {
              code: 'INVALID_ARGUMENT',
              phase: v.getState(),
              message: 'enabled must be a boolean',
              recoverable: false
            }
          };
        }
        var result = v.setCameraControlsEnabled(enabled);
        if (!result.success) {
          return {
            success: false,
            error: {
              code: result.error.code,
              phase: v.getState(),
              message: result.error.message,
              recoverable: !!result.error.recoverable
            }
          };
        }
        return { success: true, enabled: !!result.enabled };
      });
    },

    /**
     * 查询 OrbitControls 当前启用状态。
     * @returns {string} JSON 结果
     *   成功:{"success": true, "enabled": true|false}
     *   失败:{"success": false, "error": {"code": "...", "message": "..."}}
     */
    getCameraControlsEnabled: function () {
      return callViewer(function (v) {
        var result = v.getCameraControlsEnabled();
        if (!result.success) {
          return {
            success: false,
            error: {
              code: result.error.code,
              phase: v.getState(),
              message: result.error.message,
              recoverable: !!result.error.recoverable
            }
          };
        }
        return { success: true, enabled: !!result.enabled };
      });
    },

    // ===== Phase 2A-1: Scene 设置(背景 / 网格 / 灯光) =====

    /**
     * 设置场景背景颜色。
     * @param {string} color #RRGGBB 格式(6 位十六进制)
     * @returns {string} JSON 结果
     *   成功:{"success": true, "color": "#RRGGBB"}
     *   失败:{"success": false, "error": {"code": "SCENE_BACKGROUND_INVALID", ...}}
     */
    setSceneBackgroundColor: function (color) {
      return callViewer(function (v) {
        if (typeof color !== 'string') {
          return {
            success: false,
            error: {
              code: 'SCENE_BACKGROUND_INVALID',
              phase: v.getState(),
              message: 'color must be a string',
              recoverable: false
            }
          };
        }
        var result = v.setSceneBackgroundColor(color);
        if (!result.success) {
          return {
            success: false,
            error: {
              code: result.error,
              phase: v.getState(),
              message: 'setSceneBackgroundColor failed: ' + result.error,
              recoverable: false
            }
          };
        }
        return { success: true, color: result.color };
      });
    },

    /**
     * 设置网格显示。
     * @param {boolean} visible
     * @returns {string} JSON 结果
     *   成功:{"success": true, "visible": true|false}
     *   失败:{"success": false, "error": {"code": "...", ...}}
     */
    setSceneGridVisible: function (visible) {
      return callViewer(function (v) {
        if (typeof visible !== 'boolean') {
          return {
            success: false,
            error: {
              code: 'INVALID_ARGUMENT',
              phase: v.getState(),
              message: 'visible must be a boolean',
              recoverable: false
            }
          };
        }
        var result = v.setSceneGridVisible(visible);
        if (!result.success) {
          return {
            success: false,
            error: {
              code: result.error,
              phase: v.getState(),
              message: 'setSceneGridVisible failed: ' + result.error,
              recoverable: false
            }
          };
        }
        return { success: true, visible: !!result.visible };
      });
    },

    /**
     * 设置主方向光强度。
     * @param {number} intensity 0.0 ~ 4.0
     * @returns {string} JSON 结果
     *   成功:{"success": true, "intensity": <number>}
     *   失败:{"success": false, "error": {"code": "SCENE_LIGHT_INTENSITY_INVALID", ...}}
     */
    setSceneLightIntensity: function (intensity) {
      return callViewer(function (v) {
        if (typeof intensity !== 'number' || isNaN(intensity)) {
          return {
            success: false,
            error: {
              code: 'SCENE_LIGHT_INTENSITY_INVALID',
              phase: v.getState(),
              message: 'intensity must be a number',
              recoverable: false
            }
          };
        }
        var result = v.setSceneLightIntensity(intensity);
        if (!result.success) {
          return {
            success: false,
            error: {
              code: result.error,
              phase: v.getState(),
              message: 'setSceneLightIntensity failed: ' + result.error,
              recoverable: false
            }
          };
        }
        return { success: true, intensity: result.intensity };
      });
    },

    /**
     * 获取场景设置(背景颜色 / 网格 / 灯光)。
     * @returns {string} JSON 结果
     *   成功:{"success": true, "settings": {"backgroundColor": "...", "gridVisible": ..., "lightIntensity": ...}}
     *   失败:{"success": false, "error": {"code": "...", ...}}
     */
    getSceneSettings: function () {
      return callViewer(function (v) {
        var result = v.getSceneSettings();
        if (!result.success) {
          return {
            success: false,
            error: {
              code: result.error,
              phase: v.getState(),
              message: 'getSceneSettings failed: ' + result.error,
              recoverable: false
            }
          };
        }
        return {
          success: true,
          settings: {
            backgroundColor: result.backgroundColor,
            gridVisible: !!result.gridVisible,
            lightIntensity: result.lightIntensity
          }
        };
      });
    },

    // ===== Phase 2F: 环境贴图 Bridge =====

    /**
     * Phase 2F: 初始化环境贴图。
     *
     * 同步执行,使用程序化 RoomEnvironment 生成 PMREM 环境纹理。
     * 初始化失败不影响 ViewerState(仍为 READY)。
     *
     * @returns {string} JSON 结果
     *   成功:{"success": true, "state": "READY", "settings": {...}}
     *   失败:{"success": false, "error": {...}, "settings": {...}}
     */
    initializeEnvironment: function () {
      return callViewer(function (v) {
        var result = v.initializeEnvironment();
        if (result && result.success) {
          return {
            success: true,
            state: v.getState(),
            environmentState: result.state,
            settings: result.settings
          };
        }
        return {
          success: false,
          state: v.getState(),
          error: result && result.error ? result.error : {
            code: 'ENVIRONMENT_INITIALIZATION_FAILED',
            phase: v.getState(),
            message: 'initializeEnvironment failed',
            recoverable: false
          },
          settings: result && result.settings ? result.settings : undefined
        };
      });
    },

    /**
     * Phase 2F: 启用/禁用环境光照。
     *
     * @param {boolean} enabled
     * @returns {string} JSON 结果
     *   成功:{"success": true, "state": "READY", "settings": {...}}
     *   失败:{"success": false, "error": {...}}
     */
    setEnvironmentEnabled: function (enabled) {
      return callViewer(function (v) {
        if (typeof enabled !== 'boolean') {
          return {
            success: false,
            state: v.getState(),
            error: {
              code: 'ENVIRONMENT_ENABLED_INVALID',
              phase: v.getState(),
              message: 'enabled must be a boolean',
              recoverable: false
            }
          };
        }
        var result = v.setEnvironmentEnabled(enabled);
        if (result && result.success) {
          return {
            success: true,
            state: v.getState(),
            enabled: result.enabled,
            settings: result.settings
          };
        }
        return {
          success: false,
          state: v.getState(),
          error: result && result.error ? result.error : {
            code: 'ENVIRONMENT_ENABLE_FAILED',
            phase: v.getState(),
            message: 'setEnvironmentEnabled failed',
            recoverable: false
          }
        };
      });
    },

    /**
     * Phase 2F: 显示/隐藏天空盒。
     *
     * @param {boolean} visible
     * @returns {string} JSON 结果
     *   成功:{"success": true, "state": "READY", "settings": {...}}
     *   失败:{"success": false, "error": {...}}
     */
    setSkyboxVisible: function (visible) {
      return callViewer(function (v) {
        if (typeof visible !== 'boolean') {
          return {
            success: false,
            state: v.getState(),
            error: {
              code: 'SKYBOX_VISIBLE_INVALID',
              phase: v.getState(),
              message: 'visible must be a boolean',
              recoverable: false
            }
          };
        }
        var result = v.setSkyboxVisible(visible);
        if (result && result.success) {
          return {
            success: true,
            state: v.getState(),
            visible: result.visible,
            settings: result.settings
          };
        }
        return {
          success: false,
          state: v.getState(),
          error: result && result.error ? result.error : {
            code: 'SKYBOX_VISIBLE_FAILED',
            phase: v.getState(),
            message: 'setSkyboxVisible failed',
            recoverable: false
          }
        };
      });
    },

    /**
     * Phase 2F: 设置环境强度。
     *
     * @param {number} intensity 0.0 ~ 2.0
     * @returns {string} JSON 结果
     *   成功:{"success": true, "state": "READY", "settings": {...}}
     *   失败:{"success": false, "error": {...}}
     */
    setEnvironmentIntensity: function (intensity) {
      return callViewer(function (v) {
        if (typeof intensity !== 'number' || isNaN(intensity) || !isFinite(intensity)) {
          return {
            success: false,
            state: v.getState(),
            error: {
              code: 'ENVIRONMENT_INTENSITY_INVALID',
              phase: v.getState(),
              message: 'intensity must be a finite number',
              recoverable: false
            }
          };
        }
        var result = v.setEnvironmentIntensity(intensity);
        if (result && result.success) {
          return {
            success: true,
            state: v.getState(),
            intensity: result.intensity,
            settings: result.settings
          };
        }
        return {
          success: false,
          state: v.getState(),
          error: result && result.error ? result.error : {
            code: 'ENVIRONMENT_INTENSITY_FAILED',
            phase: v.getState(),
            message: 'setEnvironmentIntensity failed',
            recoverable: false
          }
        };
      });
    },

    /**
     * Phase 2F: 获取环境设置快照。
     *
     * @returns {string} JSON 结果
     *   {"success": true, "state": "READY", "settings": {...}}
     */
    getEnvironmentSettings: function () {
      return callViewer(function (v) {
        var result = v.getEnvironmentSettings();
        return {
          success: true,
          state: v.getState(),
          settings: result.settings
        };
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
    },

    // ===== Phase 1D-2C-1: 运行时诊断(获取/清除最近一条诊断记录) =====
    // 委托 window.arkTavernVrmRuntimeDiagnostics keeper(ViewerBridge.js 注册)。
    //
    // 诊断来源:
    // - ViewerModelLoader.onDiagnostic(经 ViewerCore._forwardModelLoaderDiagnostic 转发)
    //   覆盖阶段:GLTF_LOAD_STARTED / GLTF_LOAD_PROGRESS / GLTF_LOAD_FAILED /
    //   VRM_DATA_VALIDATED / MODEL_REPLACE_STARTED / MODEL_REPLACE_COMMITTED /
    //   MODEL_REPLACE_FAILED
    // - ViewerUserModelLoadCoordinator.onDiagnostic(app.js 注入的回调转发)
    //   覆盖阶段:LOAD_STARTED(含前置条件失败,保留具体 errorCode)
    // - Provider 的诊断由 ArkTS 端直接处理(不经过此 keeper)
    //
    // keeper 只保留最近一条(覆盖式),不累积历史。
    // 诊断对象字段白名单:stage / code / message / resourceId / requestMethod /
    // httpStatus / mimeType / contentLength / timestamp
    // 严禁字段:cachePath / sourceUri / fd / stack / 用户目录

    /**
     * 获取最近一条运行时诊断。
     *
     * @returns {string} JSON 结果
     *   {"success": true, "diagnostic": <object|null>}
     *   diagnostic 不含 cachePath / sourceUri / fd / stack。
     *   无记录时 diagnostic 为 null。
     */
    getVrmRuntimeDiagnostic: function () {
      var keeper = global.arkTavernVrmRuntimeDiagnostics;
      if (!keeper || typeof keeper.get !== 'function') {
        return jsonResult({
          success: false,
          error: { code: 'DIAGNOSTICS_UNAVAILABLE', message: 'arkTavernVrmRuntimeDiagnostics not registered' }
        });
      }
      try {
        return keeper.get();
      } catch (e) {
        var msg = e && e.message ? e.message : String(e);
        return jsonResult({
          success: false,
          error: { code: 'DIAGNOSTICS_CALL_FAILED', message: msg }
        });
      }
    },

    /**
     * 清除最近一条运行时诊断。
     *
     * @returns {string} JSON 结果
     *   {"success": true, "state": "DIAGNOSTIC_CLEARED"}
     */
    clearVrmRuntimeDiagnostic: function () {
      var keeper = global.arkTavernVrmRuntimeDiagnostics;
      if (!keeper || typeof keeper.clear !== 'function') {
        return jsonResult({
          success: false,
          error: { code: 'DIAGNOSTICS_UNAVAILABLE', message: 'arkTavernVrmRuntimeDiagnostics not registered' }
        });
      }
      try {
        return keeper.clear();
      } catch (e) {
        var msg = e && e.message ? e.message : String(e);
        return jsonResult({
          success: false,
          error: { code: 'DIAGNOSTICS_CALL_FAILED', message: msg }
        });
      }
    },

    // ===== Phase 3A: Animation System (只读 Bridge) =====
    // 本阶段仅提供只读查询方法,不提供 play/pause/stop/seek 等控制方法。
    // 动画系统失败不影响 ViewerState / ModelState。

    /**
     * Phase 3A: 获取动画系统状态(只读)。
     *
     * @returns {string} JSON 结果
     *   成功:{"success": true, "state": "IDLE"}
     *   state 枚举:UNINITIALIZED / IDLE / LOADING / READY / PLAYING / PAUSED / STOPPED / FAILED / DISPOSED
     */
    getAnimationState: function () {
      return callViewer(function (v) {
        var result = v.getAnimationState();
        return { success: true, state: result.state };
      });
    },

    /**
     * Phase 3A: 获取动画系统调试状态快照(只读)。
     *
     * @returns {string} JSON 结果
     *   成功:{"success": true, "debugState": {state, vrmBound, mixerReady, ...}}
     */
    getAnimationDebugState: function () {
      return callViewer(function (v) {
        var result = v.getAnimationDebugState();
        return { success: true, debugState: result.debugState };
      });
    },

    /**
     * Phase 3A 依赖补齐: 获取动画系统依赖状态(只读)。
     *
     * @returns {string} JSON 结果
     *   成功:{"success": true, "dependencyState": {available, packageName, version, loaderAvailable, clipFactoryAvailable, runtimeNetworkRequired}}
     */
    getAnimationDependencyState: function () {
      return callViewer(function (v) {
        var result = v.getAnimationDependencyState();
        return { success: true, dependencyState: result.dependencyState };
      });
    },

    // ===== Phase 3A — VRMA 文件导入与最小播放闭环 (规范 §三十) =====

    /**
     * Phase 3A: 加载 VRMA 动画资源。
     *
     * 同步返回加载启动结果 (不返回 Promise):
     *   {"success": true, "state": "LOADING", "generation": <number>}
     *   {"success": false, "error": {"code": "...", "message": "..."}}
     *
     * 异步结果通过 getAnimationState() / getAnimationDebugState() 查询。
     *
     * @param {string} resourceJson ArkTS 传入的 JSON 字符串
     *   必需字段:resourceUrl / resourceId / displayName / mimeType / size
     *   禁止字段:cachePath / sourceUri (ArkTS 已剥离)
     * @returns {string} JSON 结果
     */
    loadAnimationResource: function (resourceJson) {
      if (typeof resourceJson !== 'string' || resourceJson.length === 0) {
        return jsonResult({
          success: false,
          error: { code: 'ANIMATION_RESOURCE_INVALID', message: 'resourceJson must be a non-empty string' }
        });
      }
      var resource;
      try {
        resource = JSON.parse(resourceJson);
      } catch (e) {
        return jsonResult({
          success: false,
          error: { code: 'ANIMATION_RESOURCE_INVALID', message: 'resourceJson is not valid JSON: ' + (e && e.message ? e.message : String(e)) }
        });
      }
      if (!resource || typeof resource !== 'object') {
        return jsonResult({
          success: false,
          error: { code: 'ANIMATION_RESOURCE_INVALID', message: 'resourceJson parsed to non-object' }
        });
      }
      // 字段白名单校验 (禁止 cachePath / sourceUri)
      var forbidden = ['cachePath', 'sourceUri'];
      for (var i = 0; i < forbidden.length; i++) {
        if (Object.prototype.hasOwnProperty.call(resource, forbidden[i])) {
          return jsonResult({
            success: false,
            error: { code: 'ANIMATION_RESOURCE_INVALID', message: 'Forbidden field present: ' + forbidden[i] }
          });
        }
      }
      return callViewer(function (v) {
        var result = v.loadAnimationResource(resource);
        return result;
      });
    },

    /**
     * Phase 3A: 播放动画。
     * @returns {string} JSON 结果
     *   {"success": true, "state": "PLAYING"}
     *   {"success": false, "error": {"code": "...", "message": "..."}}
     */
    playAnimation: function () {
      return callViewer(function (v) {
        var result = v.playAnimation();
        return result;
      });
    },

    /**
     * Phase 3A: 暂停动画。
     * @returns {string} JSON 结果
     *   {"success": true, "state": "PAUSED"}
     *   {"success": false, "error": {"code": "...", "message": "..."}}
     */
    pauseAnimation: function () {
      return callViewer(function (v) {
        var result = v.pauseAnimation();
        return result;
      });
    },

    /**
     * Phase 3A: 停止动画。
     * @param {string} [optionsJson] 可选 JSON 字符串 {resetPose?: boolean}
     * @returns {string} JSON 结果
     *   {"success": true, "state": "STOPPED"}
     *   {"success": false, "error": {"code": "...", "message": "..."}}
     */
    stopAnimation: function (optionsJson) {
      var options = undefined;
      if (typeof optionsJson === 'string' && optionsJson.length > 0) {
        try {
          options = JSON.parse(optionsJson);
        } catch (e) {
          return jsonResult({
            success: false,
            error: { code: 'ANIMATION_STOP_INVALID_STATE', message: 'optionsJson is not valid JSON' }
          });
        }
      }
      return callViewer(function (v) {
        var result = v.stopAnimation(options);
        return result;
      });
    },

    // ===== Phase 3D-2 — JSON 姿势解析、应用与恢复 (规范 §三十一) =====

    /**
     * Phase 3D-2: 应用静态 JSON 姿势到当前 VRM Humanoid。
     *
     * ArkTS 从持久 JSON 文件读取后,只发送受控字段:
     *   { poseId, displayName, bones | humanBones | pose }
     * 不得包含 absolutePath / relativePath / filesDir / 文件描述符 / 原始 URI。
     *
     * 应用前 ViewerCore 会先 stopAnimation,避免动画覆盖骨骼旋转。
     *
     * @param {string} poseJson 姿势数据 JSON 字符串
     * @returns {string} JSON 结果
     *   成功:{"success": true, "state": "APPLIED", "poseId": "...", "displayName": "...", "appliedBoneCount": N, "ignoredBoneCount": M}
     *   失败:{"success": false, "error": {"code": "POSE_*", "message": "..."}}
     */
    applyPose: function (poseJson) {
      if (typeof poseJson !== 'string' || poseJson.length === 0) {
        return jsonResult({
          success: false,
          error: { code: 'POSE_DATA_INVALID', message: 'poseJson must be a non-empty string' }
        });
      }
      var poseData;
      try {
        poseData = JSON.parse(poseJson);
      } catch (e) {
        return jsonResult({
          success: false,
          error: { code: 'POSE_DATA_INVALID', message: 'poseJson is not valid JSON: ' + (e && e.message ? e.message : String(e)) }
        });
      }
      if (!poseData || typeof poseData !== 'object' || Array.isArray(poseData)) {
        return jsonResult({
          success: false,
          error: { code: 'POSE_DATA_INVALID', message: 'poseJson parsed to non-object' }
        });
      }
      // 字段白名单校验 (禁止路径相关字段)
      var forbiddenPose = ['absolutePath', 'relativePath', 'filesDir', 'fileDescriptor', 'sourceUri', 'cachePath'];
      for (var i = 0; i < forbiddenPose.length; i++) {
        if (Object.prototype.hasOwnProperty.call(poseData, forbiddenPose[i])) {
          return jsonResult({
            success: false,
            error: { code: 'POSE_DATA_INVALID', message: 'Forbidden field present: ' + forbiddenPose[i] }
          });
        }
      }
      return callViewer(function (v) {
        var result = v.applyPose(poseData);
        return result;
      });
    },

    /**
     * Phase 3D-2: 恢复 VRM Humanoid 到 normalized rest pose。
     *
     * @returns {string} JSON 结果
     *   {"success": true, "state": "IDLE"}
     *   {"success": false, "error": {"code": "POSE_*", "message": "..."}}
     */
    resetPose: function () {
      return callViewer(function (v) {
        var result = v.resetPose();
        return result;
      });
    },

    /**
     * Phase 3D-2: 获取姿势系统状态(只读)。
     *
     * @returns {string} JSON 结果
     *   {"success": true, "state": "IDLE|APPLIED|FAILED|DISPOSED", "poseId": "...", "displayName": "...", "appliedBoneCount": N, "ignoredBoneCount": M}
     */
    getPoseState: function () {
      return callViewer(function (v) {
        var result = v.getPoseState();
        return result;
      });
    },

    /**
     * Phase 3D-2: 获取姿势系统调试状态快照(只读)。
     *
     * @returns {string} JSON 结果
     *   {"success": true, "debugState": {state, vrmBound, currentPoseId, currentDisplayName, appliedBoneCount, ignoredBoneCount, lastIgnoredBones, lastErrorCode, lastErrorMessage}}
     */
    getPoseDebugState: function () {
      return callViewer(function (v) {
        var result = v.getPoseDebugState();
        return { success: true, debugState: result.debugState };
      });
    },

    // ===== Phase 3E-1 — VRM 表情系统 (规范 §三十二) =====

    /**
     * Phase 3E-1: 获取当前 VRM 真实可用 Expression 列表。
     *
     * 模型未 READY 时返回 EXPRESSION_VRM_MISSING。
     * 不得假定所有模型都支持 happy/angry/sad/relaxed/surprised/neutral。
     * 模型 READY 后只读取列表,不自动设置任何表情。
     *
     * @returns {string} JSON 结果
     *   成功: {"success": true, "expressions": [{"name":"happy","weight":0,"isPreset":true}, ...]}
     *   失败: {"success": false, "error": {"code": "EXPRESSION_VRM_MISSING|...", "message": "..."}}
     */
    getAvailableExpressions: function () {
      return callViewer(function (v) {
        var result = v.getAvailableExpressions();
        return result;
      });
    },

    /**
     * Phase 3E-1: 设置单个业务表情权重。
     *
     * 参数为 JSON 字符串,避免向 JavaScript 传文件路径或模型内部对象:
     *   {"name": "happy", "weight": 1}
     *
     * 验证:
     *   - name 非空字符串
     *   - 表达式真实存在
     *   - weight 是有限数字,范围为 0~1
     *
     * 表情错误不得改变 ViewerState / ModelState / AnimationState / PoseState。
     *
     * @param {string} paramsJson JSON 字符串 {name: string, weight: number}
     * @returns {string} JSON 结果
     *   成功: {"success": true, "state": "APPLIED", "name": "happy", "weight": 1}
     *   失败: {"success": false, "error": {"code": "EXPRESSION_*", "message": "..."}}
     */
    setExpression: function (paramsJson) {
      if (typeof paramsJson !== 'string' || paramsJson.length === 0) {
        return jsonResult({
          success: false,
          error: { code: 'EXPRESSION_NAME_INVALID', message: 'paramsJson must be a non-empty string' }
        });
      }
      var params;
      try {
        params = JSON.parse(paramsJson);
      } catch (e) {
        return jsonResult({
          success: false,
          error: { code: 'EXPRESSION_NAME_INVALID', message: 'paramsJson is not valid JSON: ' + (e && e.message ? e.message : String(e)) }
        });
      }
      if (!params || typeof params !== 'object' || Array.isArray(params)) {
        return jsonResult({
          success: false,
          error: { code: 'EXPRESSION_NAME_INVALID', message: 'paramsJson parsed to non-object' }
        });
      }
      // 字段白名单校验 (禁止路径相关字段)
      var forbiddenExp = ['absolutePath', 'relativePath', 'filesDir', 'fileDescriptor', 'sourceUri', 'cachePath'];
      for (var i = 0; i < forbiddenExp.length; i++) {
        if (Object.prototype.hasOwnProperty.call(params, forbiddenExp[i])) {
          return jsonResult({
            success: false,
            error: { code: 'EXPRESSION_NAME_INVALID', message: 'Forbidden field present: ' + forbiddenExp[i] }
          });
        }
      }
      if (typeof params.name !== 'string' || params.name.length === 0) {
        return jsonResult({
          success: false,
          error: { code: 'EXPRESSION_NAME_INVALID', message: 'params.name must be a non-empty string' }
        });
      }
      if (typeof params.weight !== 'number' || !isFinite(params.weight)) {
        return jsonResult({
          success: false,
          error: { code: 'EXPRESSION_WEIGHT_INVALID', message: 'params.weight must be a finite number' }
        });
      }
      if (params.weight < 0 || params.weight > 1) {
        return jsonResult({
          success: false,
          error: { code: 'EXPRESSION_WEIGHT_INVALID', message: 'params.weight must be in [0, 1], got ' + params.weight }
        });
      }
      return callViewer(function (v) {
        var result = v.setExpression(params.name, params.weight);
        return result;
      });
    },

    /**
     * Phase 3E-1: 清除业务表情,恢复 neutral。
     *
     * 不强制把 neutral 设置为 1。
     * 保留口型通道 aa/ee/ih/oh/ou (LIP_SYNC_CHANNELS_PRESERVED: YES)。
     * 表情错误不得改变 ViewerState / ModelState / AnimationState / PoseState。
     *
     * @returns {string} JSON 结果
     *   成功: {"success": true, "state": "READY"}
     *   失败: {"success": false, "error": {"code": "EXPRESSION_*", "message": "..."}}
     */
    resetExpression: function () {
      return callViewer(function (v) {
        var result = v.resetExpression();
        return result;
      });
    },

    /**
     * Phase 3E-1: 获取表情系统状态 (只读)。
     *
     * @returns {string} JSON 结果
     *   {"success": true, "state": "UNBOUND|READY|APPLIED|FAILED|DISPOSED", "currentExpressionName": "...", "currentExpressionWeight": N, "expressionManagerReady": bool}
     */
    getExpressionState: function () {
      return callViewer(function (v) {
        var result = v.getExpressionState();
        return result;
      });
    },

    /**
     * Phase 3E-1: 获取表情系统调试状态快照 (只读)。
     *
     * @returns {string} JSON 结果
     *   {"success": true, "debugState": {state, vrmBound, expressionManagerReady, availableExpressionCount, currentExpressionName, currentExpressionWeight, lastErrorCode, lastErrorMessage, lipSyncChannelsPreserved}}
     */
    getExpressionDebugState: function () {
      return callViewer(function (v) {
        var result = v.getExpressionDebugState();
        return { success: true, debugState: result.debugState };
      });
    },

    // ===== Phase 3E-2 — 表情别名映射、临时表情与自动恢复 (规范 §三十三 / §三十四) =====

    /**
     * Phase 3E-2: 设置临时表情。
     *
     * 参数为 JSON 字符串, 避免向 JavaScript 传文件路径或模型内部对象:
     *   {"name": "happy", "weight": 1, "durationMs": 2500, "restorePolicy": "PREVIOUS"}
     *
     * 验证:
     *   - name 非空字符串
     *   - weight 有限数字 0~1
     *   - durationMs 有限数字 100..30000
     *   - restorePolicy ∈ {PREVIOUS, RESET}
     *
     * 表情错误不得改变 ViewerState / ModelState / AnimationState / PoseState。
     *
     * @param {string} paramsJson
     * @returns {string} JSON 结果
     */
    setTemporaryExpression: function (paramsJson) {
      var parsed = parseTemporaryExpressionParams(paramsJson);
      if (parsed.error) {
        return jsonResult(parsed.error);
      }
      return callViewer(function (v) {
        return v.setTemporaryExpression(
          parsed.name, parsed.weight, parsed.durationMs, parsed.restorePolicy
        );
      });
    },

    /**
     * Phase 3E-2: 取消当前临时表情。
     *
     * 不恢复任何表情, 只清空临时状态并使旧 timeout 失效。
     *
     * @returns {string} JSON 结果
     */
    cancelTemporaryExpression: function () {
      return callViewer(function (v) {
        return v.cancelTemporaryExpression();
      });
    },

    /**
     * Phase 3E-2: 获取临时表情状态 (只读)。
     *
     * @returns {string} JSON 结果
     */
    getTemporaryExpressionState: function () {
      return callViewer(function (v) {
        return v.getTemporaryExpressionState();
      });
    },

    /**
     * Phase 3E-2: 通过业务 expressionId 设置表情 (使用持久化别名映射)。
     *
     * 参数 JSON:
     *   {"expressionId": "happy", "aliases": {"happy":"Joy"}, "weight": 1}
     *
     * @param {string} paramsJson
     * @returns {string} JSON 结果
     */
    setExpressionByAlias: function (paramsJson) {
      var parsed = parseAliasParams(paramsJson);
      if (parsed.error) {
        return jsonResult(parsed.error);
      }
      return callViewer(function (v) {
        return v.setExpressionByAlias(parsed.expressionId, parsed.aliases, parsed.weight);
      });
    },

    /**
     * Phase 3E-2: 通过业务 expressionId 设置临时表情。
     *
     * 参数 JSON:
     *   {"expressionId":"happy","aliases":{"happy":"Joy"},"weight":1,
     *    "durationMs":2500,"restorePolicy":"PREVIOUS"}
     *
     * @param {string} paramsJson
     * @returns {string} JSON 结果
     */
    setTemporaryExpressionByAlias: function (paramsJson) {
      var parsed = parseTemporaryAliasParams(paramsJson);
      if (parsed.error) {
        return jsonResult(parsed.error);
      }
      return callViewer(function (v) {
        return v.setTemporaryExpressionByAlias(
          parsed.expressionId, parsed.aliases, parsed.weight,
          parsed.durationMs, parsed.restorePolicy
        );
      });
    },

    /**
     * Phase 3E-2: 解析业务 expressionId 到模型真实 expressionName。
     *
     * 参数 JSON:
     *   {"expressionId":"happy","aliases":{"happy":"Joy"}}
     *
     * @param {string} paramsJson
     * @returns {string} JSON 结果
     */
    resolveExpressionAlias: function (paramsJson) {
      var parsed = parseResolveAliasParams(paramsJson);
      if (parsed.error) {
        return jsonResult(parsed.error);
      }
      return callViewer(function (v) {
        return v.resolveExpressionAlias(parsed.expressionId, parsed.aliases);
      });
    }
  };

  console.log('[App] arkTavernViewerBridge registered (Phase 1B + 1D-2A + 1D-2B-1 + 1D-2B-2 + 1D-2C-1 + 1D-2C-2A + 2A-1 + 2F + 3A + 3D-2 + 3E-1 + 3E-2, delegates to ViewerCore + preparedResource keeper + probe + userModelLoadCoordinator + runtimeDiagnostics keeper + cameraControls + sceneSettings + animationController + poseController + expressionController)');

  // Phase 1D-2C-2A: 记录 JS_BRIDGE_BOUND(Bridge 已注册到 window)
  emitStartupDiagnostic('JS_BRIDGE_BOUND', '', 'arkTavernViewerBridge registered');

  // ===== 页面生命周期 =====

  /**
   * DOM 就绪后启动 ViewerCore.initialize。
   * ViewerCore 内部会创建 Scene / Camera / FrameLoop,并通过 ViewerBridge 通知 ArkTS。
   */
  async function onDomReady() {
    // Phase 1D-2C-2A: 记录 ARKWEB_PAGE_END(对应 ArkTS onPageEnd 触发时机)
    emitStartupDiagnostic('ARKWEB_PAGE_END', '', 'DOM ready, page loaded');
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

  // Phase 1D-2C-2C: 标记 window.arkTavernViewerBridge 已创建并赋值完成
  // (此时 ArkTS 调用 initializeViewer 可以找到 Bridge 对象)
  if (window.__arkTavernBootstrapState) {
    window.__arkTavernBootstrapState.markBridgeReady();
  }
})(typeof window !== 'undefined' ? window : globalThis);
