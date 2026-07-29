/**
 * bootstrap.js — app.js 模块启动诊断与 Bridge 引导层(Phase 1D-2C-2C)
 *
 * 职责:
 *   - 作为普通经典脚本(非 module)在 app.js 之前加载
 *   - 维护全局启动状态机(BOOTSTRAP_READY / APP_MODULE_LOADING /
 *     APP_MODULE_EXECUTING / APP_BRIDGE_READY / APP_MODULE_FAILED)
 *   - 暴露 window.__arkTavernBootstrapState 供 app.js 标记执行进度
 *   - 暴露 window.arkTavernBootstrapBridge.getBootstrapState() 供 ArkTS 查询
 *   - 监听 window.error 与 unhandledrejection,捕获模块加载/执行失败
 *
 * 不做的事:
 *   - 不使用 import / export / type="module"
 *   - 不依赖 import map
 *   - 不记录 cachePath / sourceUri / fd / 完整 stack / 用户目录
 *
 * 安全约束:
 *   - 所有字符串字段经 sanitize 截断(phase 80 / errorCode 120 / errorMessage 500 /
 *     source 200)
 *   - 不包含完整 stack,只保留 source / line / column
 *
 * Phase 1D-2C-2C 背景:
 *   app.js 是 ES Module,若其静态 import 失败(模块解析失败 / 网络错误 /
 *   语法错误),app.js 主体不会执行,window.arkTavernViewerBridge 不会被创建。
 *   ArkTS 调用 initializeViewer 时只能拿到 BRIDGE_NOT_FOUND,无法定位真实原因。
 *   bootstrap.js 作为经典脚本在 app.js 之前加载,捕获模块加载失败并通过
 *   arkTavernBootstrapBridge.getBootstrapState() 暴露给 ArkTS。
 */
(function (global) {
  'use strict';

  var state = {
    phase: 'BOOTSTRAP_READY',
    errorCode: '',
    errorMessage: '',
    source: '',
    line: 0,
    column: 0,
    timestamp: Date.now()
  };

  function sanitize(value, maxLength) {
    var text = value === null || value === undefined
      ? ''
      : String(value);

    if (text.length > maxLength) {
      return text.slice(0, maxLength);
    }

    return text;
  }

  function update(next) {
    state = {
      phase: sanitize(next.phase, 80),
      errorCode: sanitize(next.errorCode, 120),
      errorMessage: sanitize(next.errorMessage, 500),
      source: sanitize(next.source, 200),
      line: Number(next.line) || 0,
      column: Number(next.column) || 0,
      timestamp: Date.now()
    };
  }

  global.__arkTavernBootstrapState = {
    update: update,

    markModuleLoading: function () {
      update({
        phase: 'APP_MODULE_LOADING'
      });
    },

    markModuleExecuting: function () {
      update({
        phase: 'APP_MODULE_EXECUTING'
      });
    },

    markBridgeReady: function () {
      update({
        phase: 'APP_BRIDGE_READY'
      });
    },

    getSnapshot: function () {
      return {
        phase: state.phase,
        errorCode: state.errorCode,
        errorMessage: state.errorMessage,
        source: state.source,
        line: state.line,
        column: state.column,
        timestamp: state.timestamp
      };
    },

    clearError: function () {
      update({
        phase: 'BOOTSTRAP_READY'
      });
    }
  };

  global.arkTavernBootstrapBridge = {
    getBootstrapState: function () {
      return JSON.stringify({
        success: true,
        state: global.__arkTavernBootstrapState.getSnapshot()
      });
    }
  };

  // 捕获模块加载失败(import 解析失败 / 模块脚本网络错误 / 语法错误等)
  // 注意:module script 的加载错误不会触发传统 onerror,但 window error 事件
  //       仍可能在模块执行阶段捕获异常。
  global.addEventListener('error', function (event) {
    update({
      phase: 'APP_MODULE_FAILED',
      errorCode: 'WINDOW_ERROR',
      errorMessage: event && event.message
        ? event.message
        : 'Unknown window error',
      source: event && event.filename ? event.filename : '',
      line: event && event.lineno ? event.lineno : 0,
      column: event && event.colno ? event.colno : 0
    });
  });

  // 捕获未处理的 Promise rejection(模块 import 失败可能走此路径)
  global.addEventListener('unhandledrejection', function (event) {
    var reason = event ? event.reason : null;

    update({
      phase: 'APP_MODULE_FAILED',
      errorCode: 'UNHANDLED_REJECTION',
      errorMessage: reason && reason.message
        ? reason.message
        : String(reason || 'Unknown rejection'),
      source: '',
      line: 0,
      column: 0
    });
  });
})(window);
