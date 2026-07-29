/**
 * ViewerExpressionController — VRM 表情控制器 (Phase 3E-1)
 *
 * 职责:
 *   - 绑定当前 VRM (bindVrm),枚举真实可用 Expression 列表
 *   - 设置单个业务表情权重 (setExpression)
 *   - 清除业务表情并恢复 neutral (resetExpression)
 *   - 记录 currentExpressionName / currentExpressionWeight
 *   - 模型替换时清空状态 (unbindVrm),不跨模型缓存 Expression 实例
 *   - dispose
 *
 * 不做的事:
 *   - 不做 AI 自动选择表情
 *   - 不做语音口型同步 (Lip Sync)
 *   - 不做 Blink 自动眨眼
 *   - 不做多表情混合编辑器
 *   - 不做表情时间轴 / 淡入淡出 / 持久化映射
 *   - 不做动作与表情联动
 *   - 不假定所有模型都支持 happy/angry/sad/relaxed/surprised/neutral
 *
 * Expression API (确认自 vendor/pixiv/three-vrm.module.js 3.5.5):
 *   - vrm.expressionManager -> VRMExpressionManager | null
 *   - expressionManager.expressions -> VRMExpression[] (concat copy)
 *   - expressionManager.expressionMap -> { [name]: VRMExpression } (shallow copy)
 *   - expressionManager.presetExpressionMap -> { [name]: VRMExpression } (preset only)
 *   - expressionManager.customExpressionMap -> { [name]: VRMExpression } (custom only)
 *   - expressionManager.getExpression(name) -> VRMExpression | null
 *   - expressionManager.getValue(name) -> number | null (读取 expression.weight)
 *   - expressionManager.setValue(name, weight) -> void (saturate 到 0..1)
 *   - expressionManager.resetValues() -> void (所有表情 weight=0, 包括口型)
 *   - expressionManager.update() -> void (清空 appliedWeight 并按 multiplier 重新 apply)
 *   - expressionManager.mouthExpressionNames -> ["aa","ee","ih","oh","ou"]
 *   - expressionManager.blinkExpressionNames -> ["blink","blinkLeft","blinkRight"]
 *   - expressionManager.lookAtExpressionNames -> ["lookLeft","lookRight","lookUp","lookDown"]
 *   - VRMExpression.expressionName -> string
 *   - VRMExpression.weight -> number (公有属性,直接读写)
 *   - VRMExpression.isBinary -> boolean
 *   - VRMExpression.outputWeight -> number (考虑 isBinary)
 *
 * VRMExpressionPresetName (确认自 three-vrm.module.js):
 *   aa / ih / ou / ee / oh / blink / happy / angry / sad / relaxed /
 *   lookUp / surprised / lookDown / lookLeft / lookRight / blinkLeft / blinkRight / neutral
 *
 * 设置权重后是否需要 expressionManager.update():
 *   - 是。weight 仅修改 expression.weight,需要调用 update() 才会 applyWeight 到 blend shapes。
 *   - FrameLoop 每帧也会调用 update(),但本控制器在 setExpression/resetExpression 后立即调用一次
 *     update(),确保 UI 即时反馈,不依赖下一帧。
 *
 * 口型保护策略 (LIP_SYNC_CHANNELS_PRESERVED: YES):
 *   - mouthExpressionNames = ["aa","ee","ih","oh","ou"]
 *   - resetExpression 与 setExpression 的"清除当前非口型表情"步骤,只清除非口型表情,
 *     保留 aa/ee/ih/oh/ou 的当前权重。
 *   - 由于 VRM 1.x 表情是独立通道 (expression.weight 互不干扰),此隔离能力可保证。
 *   - 不调用 resetValues() (它会清空全部,包括口型)。
 *
 * Reference:
 *   - three-vrm.module.js (VRMExpressionManager / VRMExpression / VRMExpressionPresetName)
 *   - ViewerPoseController.js (状态机 / dispose / bindVrm 模式参考)
 */

// ===== 状态枚举 =====
export var ExpressionState = {
  UNBOUND: 'UNBOUND',
  READY: 'READY',
  APPLIED: 'APPLIED',
  FAILED: 'FAILED',
  DISPOSED: 'DISPOSED'
};

// ===== 错误代码 =====
export var ExpressionErrorCode = {
  CONTROLLER_DISPOSED: 'EXPRESSION_CONTROLLER_DISPOSED',
  VRM_MISSING: 'EXPRESSION_VRM_MISSING',
  MANAGER_MISSING: 'EXPRESSION_MANAGER_MISSING',
  NAME_INVALID: 'EXPRESSION_NAME_INVALID',
  NOT_FOUND: 'EXPRESSION_NOT_FOUND',
  WEIGHT_INVALID: 'EXPRESSION_WEIGHT_INVALID',
  APPLY_FAILED: 'EXPRESSION_APPLY_FAILED'
};

/**
 * VRMExpressionPresetName 完整列表 (来自 three-vrm 3.5.5)。
 * 用于 isPreset 字段判定。不得假定模型一定支持其中任何项。
 */
var VRM_PRESET_NAMES = [
  'aa', 'ih', 'ou', 'ee', 'oh',
  'blink', 'happy', 'angry', 'sad', 'relaxed',
  'lookUp', 'surprised', 'lookDown', 'lookLeft', 'lookRight',
  'blinkLeft', 'blinkRight', 'neutral'
];

/**
 * 口型预设名 (来自 VRMExpressionManager.mouthExpressionNames)。
 * 用于 resetExpression / setExpression 时保留口型通道。
 */
var MOUTH_EXPRESSION_NAMES = ['aa', 'ee', 'ih', 'oh', 'ou'];

/**
 * 构造错误对象。
 */
function makeError(code, message) {
  return { code: code, message: message };
}

/**
 * ViewerExpressionController 构造函数。
 *
 * @param {object} options
 * @param {function} options.getCurrentVrm 返回当前 VRM 对象 (由 ViewerCore 注入)
 */
export class ViewerExpressionController {
  constructor(options) {
    /** @type {ExpressionState} */
    this._state = ExpressionState.UNBOUND;
    /** @type {object|null} 当前绑定的 VRM (不保存 Expression 实例,只保存 VRM 引用) */
    this.currentVrm = null;
    /** @type {Array<{name:string,weight:number,isPreset:boolean}>} 枚举的表情列表快照 */
    this.availableExpressions = [];
    /** @type {string} 当前已应用的业务表情名 (空字符串表示无应用) */
    this.currentExpressionName = '';
    /** @type {number} 当前已应用的业务表情权重 */
    this.currentExpressionWeight = 0;
    /** @type {string} 最近一次错误码 */
    this.lastErrorCode = '';
    /** @type {string} 最近一次错误消息 */
    this.lastErrorMessage = '';
    /** @type {boolean} 表情管理器是否就绪 (VRM 已绑定且 expressionManager 存在) */
    this.expressionManagerReady = false;
    /** @type {boolean} 口型通道是否保留 */
    this.lipSyncChannelsPreserved = true;
    /** @type {function} 获取当前 VRM 的回调 (由 ViewerCore 注入) */
    this._getCurrentVrm = (options && typeof options.getCurrentVrm === 'function')
      ? options.getCurrentVrm
      : function () { return null; };
    /** @type {boolean} 是否已销毁 */
    this._disposed = false;
  }

  /**
   * 初始化控制器。幂等。
   * @returns {{success: boolean, state: ExpressionState}}
   */
  initialize() {
    if (this._disposed) {
      return { success: false, state: ExpressionState.DISPOSED };
    }
    if (this._state === ExpressionState.UNBOUND || this._state === ExpressionState.FAILED) {
      this._state = ExpressionState.UNBOUND;
      this.lastErrorCode = '';
      this.lastErrorMessage = '';
    }
    return { success: true, state: this._state };
  }

  /**
   * 绑定 VRM。
   *
   * 行为:
   *   - 若已有旧 VRM,先解绑 (清空状态,不保存旧 Expression 实例)
   *   - 枚举新模型真实可用 Expression 列表
   *   - state = READY (若 expressionManager 存在) 或 UNBOUND (若不存在)
   *   - 不自动设置任何表情
   *
   * @param {object} vrm
   * @returns {{success: boolean, state: ExpressionState, error?: object, availableExpressions?: Array}}
   */
  bindVrm(vrm) {
    if (this._disposed) {
      return {
        success: false,
        state: ExpressionState.DISPOSED,
        error: makeError(ExpressionErrorCode.CONTROLLER_DISPOSED, 'controller disposed')
      };
    }
    if (!vrm) {
      return {
        success: false,
        state: this._state,
        error: makeError(ExpressionErrorCode.VRM_MISSING, 'vrm is null')
      };
    }
    // 若已有旧 VRM,先解绑 (清空状态,不保存旧 Expression 实例)
    if (this.currentVrm && this.currentVrm !== vrm) {
      this._clearInternalState();
    }
    this.currentVrm = vrm;

    // 枚举真实可用 Expression
    this._enumerateExpressions();

    // 不自动设置任何表情
    if (this.expressionManagerReady) {
      this._state = ExpressionState.READY;
    } else {
      this._state = ExpressionState.UNBOUND;
    }
    this.lastErrorCode = '';
    this.lastErrorMessage = '';
    return {
      success: true,
      state: this._state,
      availableExpressions: this.getAvailableExpressions()
    };
  }

  /**
   * 解绑当前 VRM。
   *
   * 行为:
   *   - 清空 currentExpressionName / currentExpressionWeight
   *   - 清空 availableExpressions
   *   - 不保存旧 Expression 实例
   *   - state = UNBOUND
   *
   * @returns {{success: boolean, state: ExpressionState}}
   */
  unbindVrm() {
    if (this._disposed) {
      return { success: false, state: ExpressionState.DISPOSED };
    }
    this._clearInternalState();
    return { success: true, state: this._state };
  }

  /**
   * 枚举当前 VRM 真实可用 Expression 列表。
   *
   * 使用 expressionManager.expressions (返回 VRMExpression 数组),
   * 读取每个 expression的 expressionName 和 weight。
   *
   * 不得假定所有模型都支持 happy/angry/sad/relaxed/surprised/neutral。
   * 若 expressionManager 不存在,availableExpressions 为空数组。
   */
  _enumerateExpressions() {
    this.availableExpressions = [];
    this.expressionManagerReady = false;
    if (!this.currentVrm) return;
    var manager = this.currentVrm.expressionManager;
    if (!manager) return;
    // 确认必要 API 存在
    if (typeof manager.getExpression !== 'function' ||
        typeof manager.setValue !== 'function' ||
        typeof manager.getValue !== 'function' ||
        typeof manager.update !== 'function') {
      // API 不完整,不枚举
      return;
    }
    this.expressionManagerReady = true;
    var expressions = manager.expressions || [];
    for (var i = 0; i < expressions.length; i++) {
      var exp = expressions[i];
      if (!exp || typeof exp.expressionName !== 'string') continue;
      var name = exp.expressionName;
      var weight = typeof exp.weight === 'number' ? exp.weight : 0;
      this.availableExpressions.push({
        name: name,
        weight: weight,
        isPreset: VRM_PRESET_NAMES.indexOf(name) !== -1
      });
    }
  }

  /**
   * 获取可用表情列表 (快照副本)。
   * 每个表情项: { name, weight, isPreset }
   * @returns {Array<{name:string,weight:number,isPreset:boolean}>}
   */
  getAvailableExpressions() {
    var result = [];
    for (var i = 0; i < this.availableExpressions.length; i++) {
      var item = this.availableExpressions[i];
      result.push({
        name: item.name,
        weight: item.weight,
        isPreset: item.isPreset
      });
    }
    return result;
  }

  /**
   * 设置单个业务表情权重。
   *
   * 验证:
   *   - Controller 未 dispose
   *   - VRM 已绑定
   *   - expressionManager 存在
   *   - name 非空字符串
   *   - 表达式真实存在 (getExpression(name) !== null)
   *   - weight 是有限数字
   *   - weight 范围为 0~1
   *
   * 执行策略:
   *   1. 清除当前非口型表情 (保留 aa/ee/ih/oh/ou)
   *   2. 设置目标表情权重 (expressionManager.setValue)
   *   3. 调用 expressionManager.update() 应用到 blend shapes
   *   4. 记录 currentExpressionName / currentExpressionWeight
   *   5. state = APPLIED
   *
   * 本阶段一次只保留一个业务表情。
   * 表情错误不得改变 ViewerState / ModelState / AnimationState / PoseState。
   *
   * @param {string} name 表情名
   * @param {number} weight 权重 (0~1)
   * @returns {{success: boolean, state?: ExpressionState, name?: string, weight?: number, error?: object}}
   */
  setExpression(name, weight) {
    if (this._disposed) {
      return {
        success: false,
        state: ExpressionState.DISPOSED,
        error: makeError(ExpressionErrorCode.CONTROLLER_DISPOSED, 'controller disposed')
      };
    }
    if (!this.currentVrm) {
      this._recordFailure(ExpressionErrorCode.VRM_MISSING, 'currentVrm is null');
      return {
        success: false,
        state: this._state,
        error: makeError(ExpressionErrorCode.VRM_MISSING, 'currentVrm is null')
      };
    }
    var manager = this.currentVrm.expressionManager;
    if (!manager) {
      this._recordFailure(ExpressionErrorCode.MANAGER_MISSING, 'expressionManager missing');
      return {
        success: false,
        state: this._state,
        error: makeError(ExpressionErrorCode.MANAGER_MISSING, 'expressionManager missing')
      };
    }
    if (typeof name !== 'string' || name.length === 0) {
      this._recordFailure(ExpressionErrorCode.NAME_INVALID, 'name must be a non-empty string');
      return {
        success: false,
        state: this._state,
        error: makeError(ExpressionErrorCode.NAME_INVALID, 'name must be a non-empty string')
      };
    }
    var expression = manager.getExpression(name);
    if (!expression) {
      this._recordFailure(ExpressionErrorCode.NOT_FOUND, 'expression not found: ' + name);
      return {
        success: false,
        state: this._state,
        error: makeError(ExpressionErrorCode.NOT_FOUND, 'expression not found: ' + name)
      };
    }
    if (typeof weight !== 'number' || !isFinite(weight)) {
      this._recordFailure(ExpressionErrorCode.WEIGHT_INVALID, 'weight must be a finite number');
      return {
        success: false,
        state: this._state,
        error: makeError(ExpressionErrorCode.WEIGHT_INVALID, 'weight must be a finite number')
      };
    }
    if (weight < 0 || weight > 1) {
      this._recordFailure(ExpressionErrorCode.WEIGHT_INVALID, 'weight must be in [0, 1], got ' + weight);
      return {
        success: false,
        state: this._state,
        error: makeError(ExpressionErrorCode.WEIGHT_INVALID, 'weight must be in [0, 1], got ' + weight)
      };
    }

    // 1. 清除当前非口型表情 (保留 aa/ee/ih/oh/ou, 保留目标表情)
    try {
      this._clearBusinessExpressions(name);
    } catch (e) {
      var clearMsg = e && e.message ? e.message : String(e);
      this._recordFailure(ExpressionErrorCode.APPLY_FAILED, 'clearBusinessExpressions threw: ' + clearMsg);
      return {
        success: false,
        state: this._state,
        error: makeError(ExpressionErrorCode.APPLY_FAILED, 'clearBusinessExpressions threw: ' + clearMsg)
      };
    }

    // 2. 设置目标表情权重
    try {
      manager.setValue(name, weight);
    } catch (e) {
      var setMsg = e && e.message ? e.message : String(e);
      this._recordFailure(ExpressionErrorCode.APPLY_FAILED, 'setValue threw: ' + setMsg);
      return {
        success: false,
        state: this._state,
        error: makeError(ExpressionErrorCode.APPLY_FAILED, 'setValue threw: ' + setMsg)
      };
    }

    // 3. 调用 update() 应用到 blend shapes
    try {
      manager.update();
    } catch (e) {
      var updateMsg = e && e.message ? e.message : String(e);
      this._recordFailure(ExpressionErrorCode.APPLY_FAILED, 'update threw: ' + updateMsg);
      return {
        success: false,
        state: this._state,
        error: makeError(ExpressionErrorCode.APPLY_FAILED, 'update threw: ' + updateMsg)
      };
    }

    // 4. 记录当前表情
    this.currentExpressionName = name;
    this.currentExpressionWeight = weight;
    this.lastErrorCode = '';
    this.lastErrorMessage = '';
    // 5. state = APPLIED
    this._state = ExpressionState.APPLIED;

    return {
      success: true,
      state: this._state,
      name: name,
      weight: weight
    };
  }

  /**
   * 清除业务表情,恢复 neutral。
   *
   * 行为:
   *   - 清除已设置的非口型表情权重 (保留 aa/ee/ih/oh/ou)
   *   - currentExpressionName = ''
   *   - currentExpressionWeight = 0
   *   - state = READY
   *   - 调用 expressionManager.update() 应用变更
   *
   * 如果模型存在 neutral 表情,不强制把 neutral 设置为 1。
   * (three-vrm 语义中 neutral 是独立表情,weight=0 不会导致显示异常;
   *  resetValues 后模型回到默认 morph target 状态,即 neutral 外观。)
   *
   * 口型保护 (LIP_SYNC_CHANNELS_PRESERVED: YES):
   *   - 不调用 resetValues() (它会清空全部,包括口型)
   *   - 只清除非口型表情,保留 aa/ee/ih/oh/ou 的当前权重
   *
   * @returns {{success: boolean, state?: ExpressionState, error?: object}}
   */
  resetExpression() {
    if (this._disposed) {
      return {
        success: false,
        state: ExpressionState.DISPOSED,
        error: makeError(ExpressionErrorCode.CONTROLLER_DISPOSED, 'controller disposed')
      };
    }
    if (!this.currentVrm) {
      this._recordFailure(ExpressionErrorCode.VRM_MISSING, 'currentVrm is null');
      return {
        success: false,
        state: this._state,
        error: makeError(ExpressionErrorCode.VRM_MISSING, 'currentVrm is null')
      };
    }
    var manager = this.currentVrm.expressionManager;
    if (!manager) {
      this._recordFailure(ExpressionErrorCode.MANAGER_MISSING, 'expressionManager missing');
      return {
        success: false,
        state: this._state,
        error: makeError(ExpressionErrorCode.MANAGER_MISSING, 'expressionManager missing')
      };
    }

    // 清除业务表情 (保留口型)
    try {
      this._clearBusinessExpressions(null);
    } catch (e) {
      var clearMsg = e && e.message ? e.message : String(e);
      this._recordFailure(ExpressionErrorCode.APPLY_FAILED, 'clearBusinessExpressions threw: ' + clearMsg);
      return {
        success: false,
        state: this._state,
        error: makeError(ExpressionErrorCode.APPLY_FAILED, 'clearBusinessExpressions threw: ' + clearMsg)
      };
    }

    // 调用 update() 应用变更
    try {
      manager.update();
    } catch (e) {
      var updateMsg = e && e.message ? e.message : String(e);
      this._recordFailure(ExpressionErrorCode.APPLY_FAILED, 'update threw: ' + updateMsg);
      return {
        success: false,
        state: this._state,
        error: makeError(ExpressionErrorCode.APPLY_FAILED, 'update threw: ' + updateMsg)
      };
    }

    this.currentExpressionName = '';
    this.currentExpressionWeight = 0;
    this.lastErrorCode = '';
    this.lastErrorMessage = '';
    this._state = ExpressionState.READY;
    return { success: true, state: this._state };
  }

  /**
   * 清除非口型业务表情,保留口型通道 (aa/ee/ih/oh/ou) 和 keepName。
   *
   * 实现细节:
   *   - 遍历 expressionManager.expressions (concat copy, 元素为同一对象引用)
   *   - 对每个 expression:
   *     - 若 expressionName === keepName:跳过
   *     - 若 expressionName 在 MOUTH_EXPRESSION_NAMES 中:跳过 (保留口型)
   *     - 否则:expression.weight = 0
   *   - 不调用 resetValues() (它会清空全部,包括口型)
   *
   * @param {string|null} keepName 要保留的表情名 (null 表示全部清除)
   * @private
   */
  _clearBusinessExpressions(keepName) {
    if (!this.currentVrm || !this.currentVrm.expressionManager) return;
    var manager = this.currentVrm.expressionManager;
    var expressions = manager.expressions || [];
    for (var i = 0; i < expressions.length; i++) {
      var exp = expressions[i];
      if (!exp) continue;
      var name = exp.expressionName;
      if (typeof name !== 'string') continue;
      if (keepName && name === keepName) continue;
      if (MOUTH_EXPRESSION_NAMES.indexOf(name) !== -1) continue;
      // 直接设置 weight = 0 (避免 setValue 的 getExpression 查找开销)
      exp.weight = 0;
    }
  }

  /**
   * 获取表情系统状态 (只读)。
   * @returns {{success: boolean, state: ExpressionState, currentExpressionName: string, currentExpressionWeight: number, expressionManagerReady: boolean}}
   */
  getExpressionState() {
    return {
      success: true,
      state: this._state,
      currentExpressionName: this.currentExpressionName,
      currentExpressionWeight: this.currentExpressionWeight,
      expressionManagerReady: this.expressionManagerReady
    };
  }

  /**
   * 获取表情系统调试状态快照 (只读)。
   *
   * 供 Bridge getExpressionDebugState 使用,字段与 ArkWebExpressionDebugState 对齐。
   * @returns {{success: boolean, debugState: object}}
   */
  getExpressionDebugState() {
    return {
      success: true,
      debugState: {
        state: this._state,
        vrmBound: !!this.currentVrm,
        expressionManagerReady: this.expressionManagerReady,
        availableExpressionCount: this.availableExpressions.length,
        currentExpressionName: this.currentExpressionName,
        currentExpressionWeight: this.currentExpressionWeight,
        lastErrorCode: this.lastErrorCode,
        lastErrorMessage: this.lastErrorMessage,
        lipSyncChannelsPreserved: this.lipSyncChannelsPreserved
      }
    };
  }

  /**
   * 销毁控制器。
   */
  dispose() {
    if (this._disposed) return;
    this._disposed = true;
    this._clearInternalState();
    this._state = ExpressionState.DISPOSED;
  }

  /** @returns {ExpressionState} */
  getState() {
    return this._state;
  }

  // ===== 内部方法 =====

  /**
   * 清空内部状态 (不调用 expressionManager)。
   * 用于模型替换 / unbindVrm / dispose。
   *
   * 不保存旧 Expression 实例。
   */
  _clearInternalState() {
    this.currentVrm = null;
    this.availableExpressions = [];
    this.currentExpressionName = '';
    this.currentExpressionWeight = 0;
    this.expressionManagerReady = false;
    this.lastErrorCode = '';
    this.lastErrorMessage = '';
    if (this._state !== ExpressionState.DISPOSED) {
      this._state = ExpressionState.UNBOUND;
    }
  }

  /**
   * 记录失败 (设置 state=FAILED + 错误码/消息)。
   * 表情错误不得改变 ViewerState / ModelState / AnimationState / PoseState。
   */
  _recordFailure(code, message) {
    this._state = ExpressionState.FAILED;
    this.lastErrorCode = code;
    this.lastErrorMessage = String(message || '');
  }
}
