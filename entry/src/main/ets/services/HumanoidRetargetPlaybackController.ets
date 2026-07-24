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
  QuaternionValue,
  Vector3Value,
  RootMotionMode
} from '../models/character3d/HumanoidMotionClip';
import { HumanoidBone } from '../models/character3d/HumanoidBone';
import { sampleMotionClip } from './HumanoidMotionSampler';
import { retargetPose, RetargetResult } from './HumanoidRetargetor';
import { Logger } from '../utils/Logger';

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
 * 人形动作重定向播放控制器。
 */
export class HumanoidRetargetPlaybackController {
  /** 配置(可选,prepare 后设置) */
  private config: RetargetPlaybackConfig | null = null;
  /** 当前状态 */
  private stateValue: RetargetPlaybackState = RetargetPlaybackState.Idle;
  /** 当前播放时间(秒) */
  private currentTime: number = 0;
  /** 上一帧时间戳(ms) */
  private lastFrameTimestamp: number = 0;
  /** 定时器 ID(-1 表示未启动) */
  private timerId: number = -1;
  /** 上次摘要日志时间(ms) */
  private lastSummaryLogTime: number = 0;
  /** 上次摘要日志时的时间(秒) */
  private lastSummaryLogCurrentTime: number = -1;
  /** 是否已 dispose */
  private disposed: boolean = false;
  /** generation(用于防止旧回调) */
  private generation: number = 0;

  /** 状态变更回调 */
  onStateChanged: OnPlaybackStateChanged | null = null;
  /** 错误回调 */
  onError: OnPlaybackError | null = null;

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
    this.lastSummaryLogCurrentTime = -1;

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

    Logger.info(LOG_TAG, 'Retarget play: clip=' + this.config.clip.name
      + ', duration=' + this.config.clip.durationSeconds.toFixed(3)
      + ', loop=' + this.config.clip.loop
      + ', currentTime=' + this.currentTime.toFixed(3));

    this.lastFrameTimestamp = Date.now();
    this.lastSummaryLogTime = this.lastFrameTimestamp;
    this.lastSummaryLogCurrentTime = -1;
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
    this.lastSummaryLogCurrentTime = -1;
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

    // 2. 重定向
    const retargetResult: RetargetResult = retargetPose(
      sourcePose,
      cfg.sourceRestPose,
      cfg.targetRestPose,
      cfg.rootMotionMode
    );

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
      cfg.rootMotionMode
    );
    Logger.info(LOG_TAG, 'Retarget tick: time=' + this.currentTime.toFixed(3)
      + ', appliedBones=' + retargetResult.appliedBoneCount
      + ', changedBones=' + retargetResult.changedBoneCount
      + ', clip=' + cfg.clip.name);

    // 调试模式:对 UpperArm/LowerArm/Hand 抽样
    if (this.lastSummaryLogCurrentTime < 0
      || (this.currentTime >= 0 && this.lastSummaryLogCurrentTime < 0)) {
      this.logDebugSample(sourcePose);
    }
    if (Math.abs(this.currentTime - 0.5) < 0.1 && this.lastSummaryLogCurrentTime < 0.5) {
      this.logDebugSample(sourcePose);
    }
    if (Math.abs(this.currentTime - 1.0) < 0.1 && this.lastSummaryLogCurrentTime < 1.0) {
      this.logDebugSample(sourcePose);
    }
    this.lastSummaryLogCurrentTime = this.currentTime;
  }

  /**
   * 调试日志:对关键骨骼抽样。
   */
  private logDebugSample(sourcePose: HumanoidPose): void {
    const cfg: RetargetPlaybackConfig | null = this.config;
    if (cfg === null) {
      return;
    }
    const sampleBones: HumanoidBone[] = [
      HumanoidBone.LeftUpperArm,
      HumanoidBone.RightUpperArm,
      HumanoidBone.LeftLowerArm,
      HumanoidBone.RightLowerArm,
      HumanoidBone.LeftHand,
      HumanoidBone.RightHand
    ];
    for (let i: number = 0; i < sampleBones.length; i++) {
      const bone: HumanoidBone = sampleBones[i];
      const bonePose = sourcePose.bones.get(bone);
      if (bonePose === undefined || bonePose.rotation === null) {
        continue;
      }
      const targetRest: BoneRestTransform | undefined = cfg.targetRestPose.bones.get(bone);
      if (targetRest === undefined) {
        continue;
      }
      // 计算目标动画旋转
      const sourceRest: BoneRestTransform | undefined = cfg.sourceRestPose.bones.get(bone);
      if (sourceRest === undefined) {
        continue;
      }
      Logger.info(LOG_TAG, 'debugSample: t=' + this.currentTime.toFixed(3)
        + ', bone=' + bone
        + ', restRot=(' + targetRest.localRotation.x.toFixed(3) + ','
        + targetRest.localRotation.y.toFixed(3) + ','
        + targetRest.localRotation.z.toFixed(3) + ','
        + targetRest.localRotation.w.toFixed(3) + ')'
        + ', sampleRot=(' + bonePose.rotation.x.toFixed(3) + ','
        + bonePose.rotation.y.toFixed(3) + ','
        + bonePose.rotation.z.toFixed(3) + ','
        + bonePose.rotation.w.toFixed(3) + ')');
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
