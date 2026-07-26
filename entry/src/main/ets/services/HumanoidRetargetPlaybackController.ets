/**
 * HumanoidRetargetPlaybackController 人形动作重定向播放控制器
 *
 * T-4.2E: 运行时控制器,管理动作播放状态、时间更新和姿态应用。
 *
 * 职责:
 * - 状态机:Idle → Preparing → Ready → Playing ↔ Paused → Stopped → Disposed
 * - 每帧:计算 deltaTime → 更新 currentTime → sample clip → retarget → 写入 SceneNode
 * - 失败时进入 Failed 状态并报告错误
 * - 停止时恢复 Rest Pose
 * - dispose 时取消定时器并恢复 Rest Pose
 *
 * 帧调度:
 * - 使用 setInterval 16ms 定时器(约 60fps)
 * - 使用真实 elapsed time 修正漂移:currentTime += (now - lastTimestamp) / 1000
 * - 不每帧固定加 0.016
 *
 * 不依赖 ArkUI,可直接单元测试(注入 SceneNode 写入回调)。
 */

import { Node, Position3, Quaternion } from '@kit.ArkGraphics3D';
import {
  HumanoidMotionClip,
  HumanoidPose,
  HumanoidRestPose,
  BoneRestTransform,
  BonePose,
  QuaternionValue,
  Vector3Value,
  RootMotionMode
} from '../models/character3d/HumanoidMotionClip';
import { HumanoidBone } from '../models/character3d/HumanoidBone';
import { sampleMotionClip } from './HumanoidMotionSampler';
import { retargetPose, RetargetResult, AxisCorrectionStat } from './HumanoidRetargetor';
import { AvatarOrientationCalibration } from '../models/character3d/AvatarOrientationCalibration';
import { Logger } from '../utils/Logger';
import { quaternionToEulerDeg } from '../utils/QuaternionUtil';

/**
 * T-4.2G-A: 四元数转欧拉角字符串(用于诊断日志)。
 */
function eulerStr(q: QuaternionValue): string {
  const euler: number[] = quaternionToEulerDeg(q);
  return '(' + euler[0].toFixed(1) + ',' + euler[1].toFixed(1) + ',' + euler[2].toFixed(1) + ')';
}

const LOG_TAG: string = 'RetargetController';

/** 帧调度间隔(ms),约 60fps */
const FRAME_INTERVAL_MS: number = 16;
/** 每秒最多一次摘要日志 */
const SUMMARY_LOG_INTERVAL_MS: number = 1000;
/** 默认播放速度 */
const DEFAULT_SPEED: number = 1.0;

/**
 * 播放器状态。
 */
export enum RetargetPlaybackState {
  /** 初始空闲 */
  Idle = 'Idle',
  /** 正在准备(加载动作、建立映射) */
  Preparing = 'Preparing',
  /** 准备就绪,可播放 */
  Ready = 'Ready',
  /** 播放中 */
  Playing = 'Playing',
  /** 暂停 */
  Paused = 'Paused',
  /** 已停止(已恢复 Rest Pose) */
  Stopped = 'Stopped',
  /** 失败 */
  Failed = 'Failed',
  /** 已释放 */
  Disposed = 'Disposed'
}

/**
 * 播放器配置。
 */
export interface RetargetPlaybackConfig {
  /** 动作 Clip */
  clip: HumanoidMotionClip;
  /** 源骨架 Rest Pose(来自 GLB nodes) */
  sourceRestPose: HumanoidRestPose;
  /** 目标骨架 Rest Pose(来自 Avatar SceneNode) */
  targetRestPose: HumanoidRestPose;
  /** bone → SceneNode 映射(目标) */
  boneNodeMap: Map<HumanoidBone, Node>;
  /** Hips 位移模式 */
  rootMotionMode: RootMotionMode;
  /** 播放速度(默认 1.0) */
  speed: number;
  /** T-4.2F: 源骨架每根骨骼的 rest 世界旋转(用于父空间 delta 转换) */
  sourceWorldRestMap: Map<HumanoidBone, QuaternionValue>;
  /** T-4.2G: 方向校准(可选,为 null 时无校正) */
  calibration: AvatarOrientationCalibration | null;
}

/**
 * 播放器构造结果。
 */
export interface RetargetPlaybackPrepareResult {
  /** 是否成功 */
  success: boolean;
  /** 错误信息 */
  errorMessage: string;
}

/**
 * 状态变更回调。
 */
export type OnPlaybackStateChanged = (state: RetargetPlaybackState) => void;

/**
 * 错误回调。
 */
export type OnPlaybackError = (message: string) => void;

/**
 * T-4.2G-A2: 帧应用后回调(每帧 retarget 写入 SceneNode 之后触发)。
 *
 * 用于让 TargetAvatarSkeletonController 同步刷新骨架几何位置。
 */
export type OnPlaybackFrameApplied = () => void;

/**
 * T-4.2G-A2: 停止后回调(Rest Pose 已恢复到 SceneNode 之后触发)。
 *
 * 用于让 TargetAvatarSkeletonController 同步恢复骨架到 Rest Pose。
 */
export type OnPlaybackStopped = () => void;

/**
 * 人形动作重定向播放控制器。
 */
export class HumanoidRetargetPlaybackController {
  /** 配置(可选,prepare 后设置) */
  private config: RetargetPlaybackConfig | null = null;
  /** 当前状态 */
  private stateValue: RetargetPlaybackState = RetargetPlaybackState.Idle;
  /** 当前播放时间(秒) */
  private currentTime: number = 0;
  /** T-4.2G-A: 帧计数器(用于诊断日志频率控制) */
  private frameCounter: number = 0;
  /** 上一帧时间戳(ms) */
  private lastFrameTimestamp: number = 0;
  /** 定时器 ID(-1 表示未启动) */
  private timerId: number = -1;
  /** 上次摘要日志时间(ms) */
  private lastSummaryLogTime: number = 0;
  /** 是否已 dispose */
  private disposed: boolean = false;
  /** generation(用于防止旧回调) */
  private generation: number = 0;
  /** T-4.2F: 分段日志位掩码(bit0=t=0, bit1=t≈0.5, bit2=t≈1.0) */
  private segmentLogMask: number = 0;

  /** 状态变更回调 */
  onStateChanged: OnPlaybackStateChanged | null = null;
  /** 错误回调 */
  onError: OnPlaybackError | null = null;
  /** T-4.2G-A2: 帧应用后回调(每帧 retarget 写入 SceneNode 之后触发) */
  onFrameApplied: OnPlaybackFrameApplied | null = null;
  /** T-4.2G-A2: 停止后回调(Rest Pose 已恢复到 SceneNode 之后触发) */
  onStopped: OnPlaybackStopped | null = null;

  /**
   * 准备播放(注入配置,进入 Ready 状态)。
   */
  prepare(config: RetargetPlaybackConfig): RetargetPlaybackPrepareResult {
    if (this.disposed) {
      return { success: false, errorMessage: 'controller disposed' };
    }
    if (this.stateValue === RetargetPlaybackState.Playing) {
      this.stopInternal();
    }
    this.generation++;
    this.config = config;
    this.currentTime = 0;
    this.lastFrameTimestamp = 0;
    this.lastSummaryLogTime = 0;
    this.segmentLogMask = 0;

    // 验证配置
    if (config.clip.tracks.length === 0) {
      this.setState(RetargetPlaybackState.Failed);
      const msg: string = '动作 clip 无轨道';
      this.fireError(msg);
      return { success: false, errorMessage: msg };
    }
    if (config.boneNodeMap.size === 0) {
      this.setState(RetargetPlaybackState.Failed);
      const msg: string = '目标骨骼映射为空';
      this.fireError(msg);
      return { success: false, errorMessage: msg };
    }

    Logger.info(LOG_TAG, 'Retarget mapping: sourceBones=' + config.sourceRestPose.bones.size
      + ', targetBones=' + config.targetRestPose.bones.size
      + ', mappedBones=' + config.boneNodeMap.size
      + ', clip=' + config.clip.name
      + ', duration=' + config.clip.durationSeconds.toFixed(3)
      + ', loop=' + config.clip.loop);

    this.setState(RetargetPlaybackState.Ready);
    return { success: true, errorMessage: '' };
  }

  /**
   * 播放(从 Ready/Paused/Stopped 进入 Playing)。
   */
  play(): void {
    if (this.disposed) {
      return;
    }
    if (this.config === null) {
      this.fireError('未准备配置');
      return;
    }
    if (this.stateValue === RetargetPlaybackState.Playing) {
      return;
    }
    if (this.stateValue !== RetargetPlaybackState.Ready
      && this.stateValue !== RetargetPlaybackState.Paused
      && this.stateValue !== RetargetPlaybackState.Stopped) {
      this.fireError('当前状态不允许播放: ' + this.stateValue);
      return;
    }

    // T-4.2E-Closeout: 从 Stopped 状态恢复播放时,currentTime 应重置为 0
    // (满足"停止后重新播放从 0 开始"语义;Paused 状态保留 currentTime)
    if (this.stateValue === RetargetPlaybackState.Stopped) {
      this.currentTime = 0;
      this.segmentLogMask = 0;
    }

    Logger.info(LOG_TAG, 'Retarget play: clip=' + this.config.clip.name
      + ', duration=' + this.config.clip.durationSeconds.toFixed(3)
      + ', loop=' + this.config.clip.loop
      + ', currentTime=' + this.currentTime.toFixed(3));

    this.lastFrameTimestamp = Date.now();
    this.lastSummaryLogTime = this.lastFrameTimestamp;
    this.setState(RetargetPlaybackState.Playing);
    this.startTimer();
  }

  /**
   * 暂停(从 Playing 进入 Paused)。
   */
  pause(): void {
    if (this.disposed || this.stateValue !== RetargetPlaybackState.Playing) {
      return;
    }
    this.stopTimer();
    this.setState(RetargetPlaybackState.Paused);
    Logger.info(LOG_TAG, 'Retarget pause: clip=' + (this.config !== null ? this.config.clip.name : 'null')
      + ', currentTime=' + this.currentTime.toFixed(3));
  }

  /**
   * 重播(回到 0 秒并播放)。
   */
  replay(): void {
    if (this.disposed || this.config === null) {
      return;
    }
    this.currentTime = 0;
    this.lastFrameTimestamp = Date.now();
    this.lastSummaryLogTime = this.lastFrameTimestamp;
    this.segmentLogMask = 0;
    if (this.stateValue !== RetargetPlaybackState.Playing) {
      this.setState(RetargetPlaybackState.Playing);
      this.startTimer();
    }
    Logger.info(LOG_TAG, 'Retarget replay: clip=' + this.config.clip.name);
  }

  /**
   * 停止(回到 Rest Pose)。
   */
  stop(): void {
    if (this.disposed) {
      return;
    }
    this.stopInternal();
    this.restoreTargetRestPose();
    this.currentTime = 0;
    if (this.stateValue !== RetargetPlaybackState.Failed) {
      this.setState(RetargetPlaybackState.Stopped);
    }
    Logger.info(LOG_TAG, 'Retarget stop: rest pose restored');
  }

  /**
   * 跳转到指定时间(不改变状态)。
   */
  seek(timeSeconds: number): void {
    if (this.disposed || this.config === null) {
      return;
    }
    const duration: number = this.config.clip.durationSeconds;
    if (this.config.clip.loop) {
      this.currentTime = duration > 0 ? timeSeconds % duration : 0;
    } else {
      this.currentTime = Math.max(0, Math.min(duration, timeSeconds));
    }
    this.segmentLogMask = 0;
    // 立即应用一帧
    this.applyFrame();
  }

  /**
   * 释放资源(恢复 Rest Pose,取消定时器)。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.stopTimer();
    if (this.config !== null) {
      this.restoreTargetRestPose();
    }
    this.config = null;
    this.setState(RetargetPlaybackState.Disposed);
    Logger.info(LOG_TAG, 'Retarget dispose: resources released');
  }

  /**
   * 获取当前状态。
   */
  getState(): RetargetPlaybackState {
    return this.stateValue;
  }

  /**
   * 获取当前播放时间(秒)。
   */
  getCurrentTime(): number {
    return this.currentTime;
  }

  /**
   * 获取动作时长(秒)。
   */
  getDuration(): number {
    return this.config !== null ? this.config.clip.durationSeconds : 0;
  }

  /**
   * 获取当前 clip 名称。
   */
  getClipName(): string {
    return this.config !== null ? this.config.clip.name : '';
  }

  /**
   * 获取当前循环模式。
   */
  isLoop(): boolean {
    return this.config !== null ? this.config.clip.loop : false;
  }

  /**
   * T-4.2G: 更新方向校准(运行时切换,无需重新 prepare)。
   *
   * 用于手动校准 UI 切换模式时,立即生效而不重建 Scene/Clip/映射。
   *
   * 行为:
   * - 若控制器未 prepare(config===null):返回 false,但不报错
   * - 若正在播放:更新后下一帧自动应用新校准
   * - 若已停止:更新后下次 play 时应用新校准
   * - 不重置 currentTime(保持播放连续性)
   *
   * @param calibration 新的方向校准(可为 null 表示关闭校准)
   * @returns true 表示已更新;false 表示控制器未准备
   */
  updateCalibration(calibration: AvatarOrientationCalibration | null): boolean {
    if (this.disposed || this.config === null) {
      return false;
    }
    this.config.calibration = calibration;
    Logger.info(LOG_TAG, 'updateCalibration: updated, mode='
      + (calibration !== null ? calibration.mode : 'null')
      + ', isManual=' + (calibration !== null ? calibration.isManualOverride : false)
      + ', state=' + this.stateValue);
    // 立即应用一帧,避免状态切换的视觉延迟
    if (this.stateValue === RetargetPlaybackState.Playing
      || this.stateValue === RetargetPlaybackState.Paused
      || this.stateValue === RetargetPlaybackState.Ready) {
      this.applyFrame();
    }
    return true;
  }

  // ==================== 内部实现 ====================

  /**
   * 启动帧调度定时器。
   */
  private startTimer(): void {
    if (this.timerId !== -1) {
      return;
    }
    this.timerId = setInterval((): void => {
      this.onFrameTick();
    }, FRAME_INTERVAL_MS);
  }

  /**
   * 停止帧调度定时器。
   */
  private stopTimer(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  /**
   * 帧调度回调。
   */
  private onFrameTick(): void {
    if (this.disposed || this.config === null) {
      this.stopTimer();
      return;
    }
    if (this.stateValue !== RetargetPlaybackState.Playing) {
      this.stopTimer();
      return;
    }

    // 1. 计算 deltaTime(真实 elapsed time)
    const now: number = Date.now();
    const deltaMs: number = now - this.lastFrameTimestamp;
    this.lastFrameTimestamp = now;
    const deltaTime: number = (deltaMs / 1000) * (this.config.speed > 0 ? this.config.speed : DEFAULT_SPEED);

    // 2. 更新 currentTime
    this.currentTime += deltaTime;
    const duration: number = this.config.clip.durationSeconds;
    if (duration > 0) {
      if (this.config.clip.loop) {
        if (this.currentTime >= duration) {
          this.currentTime = this.currentTime % duration;
        }
      } else {
        // once: 到达结尾,停止
        if (this.currentTime >= duration) {
          this.currentTime = duration;
          this.applyFrame();
          this.stopTimer();
          this.setState(RetargetPlaybackState.Stopped);
          Logger.info(LOG_TAG, 'Retarget once finished: clip=' + this.config.clip.name);
          return;
        }
      }
    }

    // 3. 应用一帧
    this.applyFrame();

    // 4. 摘要日志(每秒最多一次)
    if (now - this.lastSummaryLogTime >= SUMMARY_LOG_INTERVAL_MS) {
      this.logSummary();
      this.lastSummaryLogTime = now;
    }

    // 5. T-4.2F: 分段诊断日志(仅 t=0/0.5/1.0 三个关键时刻,每个最多打一次)
    this.maybeLogSegment();
  }

  /**
   * 采样、重定向并写入 SceneNode。
   */
  private applyFrame(): void {
    const cfg: RetargetPlaybackConfig | null = this.config;
    if (cfg === null) {
      return;
    }

    // 1. 采样 clip
    const sourcePose: HumanoidPose = sampleMotionClip(cfg.clip, this.currentTime);

    // 2. 重定向(T-4.2F: 传入 sourceWorldRestMap 用于父空间 delta 转换)
    //    T-4.2G: 传入 calibration 进行方向校准(Alignment Transform + 左右镜像)
    const retargetResult: RetargetResult = retargetPose(
      sourcePose,
      cfg.sourceRestPose,
      cfg.targetRestPose,
      cfg.sourceWorldRestMap,
      cfg.rootMotionMode,
      cfg.calibration
    );

    // T-4.2G-A: 诊断日志(每 30 帧 ≈ 0.5s 输出一次关键骨骼旋转值)
    this.frameCounter++;
    if (this.frameCounter % 30 === 1) {
      this.logRetargetDiagnostics(sourcePose, retargetResult, cfg);
    }

    // 3. 写入 SceneNode
    retargetResult.rotations.forEach((rot: QuaternionValue, bone: HumanoidBone) => {
      const node: Node | undefined = cfg.boneNodeMap.get(bone);
      if (node !== undefined) {
        try {
          const q: Quaternion = { x: rot.x, y: rot.y, z: rot.z, w: rot.w };
          node.rotation = q;
        } catch (_e) {
          // ignore
        }
      }
    });

    // 写入 Hips 位移
    retargetResult.translations.forEach((trans: Vector3Value, bone: HumanoidBone) => {
      if (bone !== HumanoidBone.Hips) {
        return;
      }
      const node: Node | undefined = cfg.boneNodeMap.get(bone);
      if (node !== undefined) {
        try {
          const p: Position3 = { x: trans.x, y: trans.y, z: trans.z };
          node.position = p;
        } catch (_e) {
          // ignore
        }
      }
    });

    // T-4.2G-A2: 通知骨架控制器刷新(必须在所有 SceneNode 写入完成后)
    if (this.onFrameApplied !== null) {
      try {
        this.onFrameApplied();
      } catch (e) {
        Logger.warn(LOG_TAG, 'onFrameApplied callback failed: ' + (e as Error)?.message);
      }
    }
  }

  /**
   * T-4.2G-A: 输出重定向诊断日志,对比 source/target/rest 的旋转值。
   */
  private logRetargetDiagnostics(
    sourcePose: HumanoidPose,
    retargetResult: RetargetResult,
    cfg: RetargetPlaybackConfig
  ): void {
    const bones: HumanoidBone[] = [
      HumanoidBone.RightUpperArm,
      HumanoidBone.RightLowerArm,
      HumanoidBone.LeftUpperArm,
      HumanoidBone.LeftLowerArm
    ];
    Logger.info(LOG_TAG, 'Retarget diag t=' + this.currentTime.toFixed(3)
      + 's frame=' + this.frameCounter);
    for (let i: number = 0; i < bones.length; i++) {
      const bone: HumanoidBone = bones[i];
      const srcPose: BonePose | undefined = sourcePose.bones.get(bone);
      const srcRest: BoneRestTransform | undefined = cfg.sourceRestPose.bones.get(bone);
      const tgtRest: BoneRestTransform | undefined = cfg.targetRestPose.bones.get(bone);
      const tgtAnim: QuaternionValue | undefined = retargetResult.rotations.get(bone);
      const srcEuler: string = (srcPose !== undefined && srcPose.rotation !== null)
        ? eulerStr(srcPose.rotation) : 'null';
      const srcRestEuler: string = srcRest !== undefined ? eulerStr(srcRest.localRotation) : 'null';
      const tgtRestEuler: string = tgtRest !== undefined ? eulerStr(tgtRest.localRotation) : 'null';
      const tgtAnimEuler: string = tgtAnim !== undefined ? eulerStr(tgtAnim) : 'null';
      Logger.info(LOG_TAG, '  ' + bone
        + ' srcAnim=' + srcEuler
        + ' srcRest=' + srcRestEuler
        + ' tgtRest=' + tgtRestEuler
        + ' tgtAnim=' + tgtAnimEuler);
    }
  }

  /**
   * 恢复目标 Rest Pose。
   */
  private restoreTargetRestPose(): void {
    const cfg: RetargetPlaybackConfig | null = this.config;
    if (cfg === null) {
      return;
    }
    let restored: number = 0;
    cfg.boneNodeMap.forEach((node: Node, bone: HumanoidBone) => {
      const rest: BoneRestTransform | undefined = cfg.targetRestPose.bones.get(bone);
      if (rest === undefined) {
        return;
      }
      try {
        const q: Quaternion = {
          x: rest.localRotation.x,
          y: rest.localRotation.y,
          z: rest.localRotation.z,
          w: rest.localRotation.w
        };
        node.rotation = q;
      } catch (_e) {
        // ignore
      }
      if (bone === HumanoidBone.Hips) {
        try {
          const p: Position3 = {
            x: rest.localPosition.x,
            y: rest.localPosition.y,
            z: rest.localPosition.z
          };
          node.position = p;
        } catch (_e) {
          // ignore
        }
      }
      restored++;
    });
    Logger.info(LOG_TAG, 'restoreTargetRestPose: restored=' + restored);

    // T-4.2G-A2: 通知骨架控制器恢复 Rest Pose(必须在所有 SceneNode 写入完成后)
    if (this.onStopped !== null) {
      try {
        this.onStopped();
      } catch (e) {
        Logger.warn(LOG_TAG, 'onStopped callback failed: ' + (e as Error)?.message);
      }
    }
  }

  /**
   * 内部停止(不修改状态,不恢复 Rest Pose)。
   */
  private stopInternal(): void {
    this.stopTimer();
  }

  /**
   * 输出摘要日志。
   */
  private logSummary(): void {
    const cfg: RetargetPlaybackConfig | null = this.config;
    if (cfg === null) {
      return;
    }
    const sourcePose: HumanoidPose = sampleMotionClip(cfg.clip, this.currentTime);
    const retargetResult: RetargetResult = retargetPose(
      sourcePose,
      cfg.sourceRestPose,
      cfg.targetRestPose,
      cfg.sourceWorldRestMap,
      cfg.rootMotionMode,
      cfg.calibration
    );
    // T-4.2F: 统计手臂链变化(LowerArm/Hand 是否参与)
    let upperArmChanged: boolean = false;
    let lowerArmChanged: boolean = false;
    let handChanged: boolean = false;
    for (let i: number = 0; i < retargetResult.changedBones.length; i++) {
      const b: HumanoidBone = retargetResult.changedBones[i];
      if (b === HumanoidBone.LeftUpperArm || b === HumanoidBone.RightUpperArm) {
        upperArmChanged = true;
      } else if (b === HumanoidBone.LeftLowerArm || b === HumanoidBone.RightLowerArm) {
        lowerArmChanged = true;
      } else if (b === HumanoidBone.LeftHand || b === HumanoidBone.RightHand) {
        handChanged = true;
      }
    }
    Logger.info(LOG_TAG, 'Retarget summary: time=' + this.currentTime.toFixed(3)
      + ', clip=' + cfg.clip.name
      + ', appliedBones=' + retargetResult.appliedBoneCount
      + ', changedBones=' + retargetResult.changedBoneCount
      + ', upperArmChanged=' + upperArmChanged
      + ', lowerArmChanged=' + lowerArmChanged
      + ', handChanged=' + handChanged);
  }

  /**
   * T-4.2F: 分段诊断日志(仅 t=0/0.5/1.0 三个关键时刻)。
   *
   * 每个关键时刻最多打一次,记录:
   * - sourceDelta 角度
   * - worldDelta 角度(应与 sourceDelta 相同)
   * - targetApplied 角度
   * - targetRest 角度
   * - changed 标记
   *
   * 只对 RightUpperArm / RightLowerArm / RightHand 三根关键手臂骨骼输出。
   */
  private maybeLogSegment(): void {
    const cfg: RetargetPlaybackConfig | null = this.config;
    if (cfg === null) {
      return;
    }
    const t: number = this.currentTime;
    // 判断是否到达某个分段点(±0.05s 容差)
    let segmentBit: number = 0;
    let segmentLabel: string = '';
    if ((this.segmentLogMask & 0x1) === 0 && t >= 0.0 && t <= 0.05) {
      segmentBit = 0x1;
      segmentLabel = 't=0.0';
    } else if ((this.segmentLogMask & 0x2) === 0 && t >= 0.45 && t <= 0.55) {
      segmentBit = 0x2;
      segmentLabel = 't=0.5';
    } else if ((this.segmentLogMask & 0x4) === 0 && t >= 0.95 && t <= 1.05) {
      segmentBit = 0x4;
      segmentLabel = 't=1.0';
    }
    if (segmentBit === 0) {
      return;
    }
    this.segmentLogMask |= segmentBit;

    // 采样并重定向,获取 axisCorrectionStats
    const sourcePose: HumanoidPose = sampleMotionClip(cfg.clip, t);
    const retargetResult: RetargetResult = retargetPose(
      sourcePose,
      cfg.sourceRestPose,
      cfg.targetRestPose,
      cfg.sourceWorldRestMap,
      cfg.rootMotionMode,
      cfg.calibration
    );

    // 关注的手臂骨骼
    const focusBones: HumanoidBone[] = [
      HumanoidBone.RightUpperArm,
      HumanoidBone.RightLowerArm,
      HumanoidBone.RightHand
    ];
    let logLine: string = 'Retarget sample: clip=' + cfg.clip.name
      + ', time=' + segmentLabel
      + ' (' + t.toFixed(3) + 's)';
    Logger.info(LOG_TAG, logLine);
    for (let i: number = 0; i < focusBones.length; i++) {
      const focusBone: HumanoidBone = focusBones[i];
      let stat: AxisCorrectionStat | null = null;
      for (let j: number = 0; j < retargetResult.axisCorrectionStats.length; j++) {
        if (retargetResult.axisCorrectionStats[j].bone === focusBone) {
          stat = retargetResult.axisCorrectionStats[j];
          break;
        }
      }
      if (stat === null) {
        Logger.info(LOG_TAG, '  bone=' + focusBone + ' (no stat, skipped)');
        continue;
      }
      const nodeExists: boolean = cfg.boneNodeMap.has(focusBone);
      Logger.info(LOG_TAG, '  bone=' + focusBone
        + ', sourceDelta=' + stat.sourceDeltaAngleDeg.toFixed(1) + 'deg'
        + ', worldDelta=' + stat.worldDeltaAngleDeg.toFixed(1) + 'deg'
        + ', targetApplied=' + stat.targetAppliedAngleDeg.toFixed(1) + 'deg'
        + ', targetRest=' + stat.targetRestAngleDeg.toFixed(1) + 'deg'
        + ', changed=' + stat.changed
        + ', targetNodeExists=' + nodeExists);
    }
  }

  /**
   * 设置状态并通知 UI。
   */
  private setState(state: RetargetPlaybackState): void {
    this.stateValue = state;
    if (this.onStateChanged !== null) {
      this.onStateChanged(state);
    }
  }

  /**
   * 触发错误回调。
   */
  private fireError(message: string): void {
    Logger.error(LOG_TAG, 'Retarget error: ' + message);
    if (this.onError !== null) {
      this.onError(message);
    }
  }
}
