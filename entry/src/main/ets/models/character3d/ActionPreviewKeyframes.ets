/**
 * ActionPreviewKeyframes 动作预览关键帧数据
 *
 * T-3D.6C-A: 为 15 个内置动作提供预定义骨骼关键帧。
 *
 * 约束:
 * - 不解析 GLB 动画文件
 * - 不随机旋转
 * - 不整体平移冒充动作
 * - 使用预定义骨骼关键帧,确保每个动作视觉可区分
 *
 * 旋转约定(2D 前视图,Y 轴向下):
 * - 0° = 静止位置
 * - 正角度 = 顺时针旋转
 * - RightShoulder: 负值 = 右臂向外/向上抬起
 * - LeftShoulder: 正值 = 左臂向外/向上抬起
 * - Neck/Head: 正值 = 头部右倾,负值 = 头部左倾
 */

import { BoneRotationEntry } from './DefaultHumanoidSkeleton';

/**
 * 骨骼姿态关键帧。
 */
export interface BonePoseFrame {
  /** 时间戳(毫秒) */
  timestamp: number;
  /** 骨骼旋转增量列表(未列出的骨骼为 0°) */
  rotations: BoneRotationEntry[];
  /** 根节点 X 偏移(呼吸/跳跃等根运动) */
  rootOffsetX: number;
  /** 根节点 Y 偏移 */
  rootOffsetY: number;
}

/**
 * 创建空旋转列表的辅助函数(减少代码量)。
 */
function none(): BoneRotationEntry[] {
  return [];
}

/**
 * 单骨骼旋转辅助函数。
 */
function rot(bone: string, angle: number): BoneRotationEntry {
  return { bone: bone, angle: angle };
}

// ========== Idle 待机(呼吸,4s 循环) ==========

const IDLE_FRAMES: BonePoseFrame[] = [
  { timestamp: 0, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 2000, rotations: [
    rot('Spine', 2),
    rot('LeftShoulder', -4),
    rot('RightShoulder', 4)
  ], rootOffsetX: 0, rootOffsetY: -1 },
  { timestamp: 4000, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 }
];

// ========== Listening 倾听(头部轻微转动,3s 循环) ==========

const LISTENING_FRAMES: BonePoseFrame[] = [
  { timestamp: 0, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 1000, rotations: [rot('Neck', 8)], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 2000, rotations: [rot('Neck', -8)], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 3000, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 }
];

// ========== Thinking 思考(头倾+手托腮,3s 循环) ==========

const THINKING_FRAMES: BonePoseFrame[] = [
  { timestamp: 0, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 800, rotations: [
    rot('Neck', 12),
    rot('RightShoulder', -110),
    rot('RightArm', -35)
  ], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 2200, rotations: [
    rot('Neck', 12),
    rot('RightShoulder', -110),
    rot('RightArm', -35)
  ], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 3000, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 }
];

// ========== Speaking 说话(手势交替,2s 循环) ==========

const SPEAKING_FRAMES: BonePoseFrame[] = [
  { timestamp: 0, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 500, rotations: [
    rot('RightShoulder', -35),
    rot('RightArm', 25)
  ], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 1000, rotations: [
    rot('RightShoulder', -12),
    rot('RightArm', 8)
  ], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 1500, rotations: [
    rot('LeftShoulder', 35),
    rot('LeftArm', -25)
  ], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 2000, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 }
];

// ========== Greeting 问候(轻微鞠躬,1.8s 单次) ==========

const GREETING_FRAMES: BonePoseFrame[] = [
  { timestamp: 0, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 500, rotations: [
    rot('Spine', 6),
    rot('Neck', -5),
    rot('RightShoulder', -20),
    rot('RightArm', 15)
  ], rootOffsetX: 0, rootOffsetY: 3 },
  { timestamp: 1200, rotations: [
    rot('Spine', 6),
    rot('Neck', -5),
    rot('RightShoulder', -20),
    rot('RightArm', 15)
  ], rootOffsetX: 0, rootOffsetY: 3 },
  { timestamp: 1800, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 }
];

// ========== Wave 挥手(抬臂摆手,2s 单次) ==========

const WAVE_FRAMES: BonePoseFrame[] = [
  { timestamp: 0, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 200, rotations: [
    rot('RightShoulder', -120)
  ], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 500, rotations: [
    rot('RightShoulder', -120),
    rot('RightArm', -25)
  ], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 800, rotations: [
    rot('RightShoulder', -120),
    rot('RightArm', 25)
  ], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 1100, rotations: [
    rot('RightShoulder', -120),
    rot('RightArm', -25)
  ], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 1400, rotations: [
    rot('RightShoulder', -120),
    rot('RightArm', 25)
  ], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 1700, rotations: [
    rot('RightShoulder', -120),
    rot('RightArm', 0)
  ], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 2000, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 }
];

// ========== Nod 点头(头部上下,1.2s 单次) ==========

const NOD_FRAMES: BonePoseFrame[] = [
  { timestamp: 0, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 300, rotations: [
    rot('Neck', 6),
    rot('Head', 4)
  ], rootOffsetX: 0, rootOffsetY: 2 },
  { timestamp: 600, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 900, rotations: [
    rot('Neck', 6),
    rot('Head', 4)
  ], rootOffsetX: 0, rootOffsetY: 2 },
  { timestamp: 1200, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 }
];

// ========== ShakeHead 摇头(头部左右,1.2s 单次) ==========

const SHAKEHEAD_FRAMES: BonePoseFrame[] = [
  { timestamp: 0, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 300, rotations: [rot('Neck', -14)], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 600, rotations: [rot('Neck', 14)], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 900, rotations: [rot('Neck', -14)], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 1200, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 }
];

// ========== Happy 开心(双臂展开,1.8s 单次) ==========

const HAPPY_FRAMES: BonePoseFrame[] = [
  { timestamp: 0, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 400, rotations: [
    rot('LeftShoulder', 75),
    rot('RightShoulder', -75),
    rot('Neck', -3)
  ], rootOffsetX: 0, rootOffsetY: -1 },
  { timestamp: 800, rotations: [
    rot('LeftShoulder', 90),
    rot('RightShoulder', -90),
    rot('Neck', -5)
  ], rootOffsetX: 0, rootOffsetY: -2 },
  { timestamp: 1200, rotations: [
    rot('LeftShoulder', 75),
    rot('RightShoulder', -75),
    rot('Neck', -3)
  ], rootOffsetX: 0, rootOffsetY: -1 },
  { timestamp: 1800, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 }
];

// ========== Confused 疑惑(头倾+耸肩,2s 单次) ==========

const CONFUSED_FRAMES: BonePoseFrame[] = [
  { timestamp: 0, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 500, rotations: [
    rot('Neck', -12),
    rot('RightShoulder', -18),
    rot('LeftShoulder', 10)
  ], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 1000, rotations: [
    rot('Neck', 12),
    rot('LeftShoulder', 18),
    rot('RightShoulder', -10)
  ], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 1500, rotations: [
    rot('Neck', -12),
    rot('RightShoulder', -18),
    rot('LeftShoulder', 10)
  ], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 2000, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 }
];

// ========== Sad 难过(低头+双臂内收,2s 单次) ==========

const SAD_FRAMES: BonePoseFrame[] = [
  { timestamp: 0, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 500, rotations: [
    rot('Neck', 6),
    rot('Head', 3),
    rot('Spine', -4),
    rot('LeftShoulder', -12),
    rot('RightShoulder', 12)
  ], rootOffsetX: 0, rootOffsetY: 2 },
  { timestamp: 1500, rotations: [
    rot('Neck', 6),
    rot('Head', 3),
    rot('Spine', -4),
    rot('LeftShoulder', -12),
    rot('RightShoulder', 12)
  ], rootOffsetX: 0, rootOffsetY: 2 },
  { timestamp: 2000, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 }
];

// ========== Angry 生气(握拳+前倾,1.8s 单次) ==========

const ANGRY_FRAMES: BonePoseFrame[] = [
  { timestamp: 0, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 400, rotations: [
    rot('LeftArm', 45),
    rot('RightArm', -45),
    rot('Spine', 3),
    rot('Neck', -4)
  ], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 800, rotations: [
    rot('LeftArm', 55),
    rot('RightArm', -55),
    rot('Spine', 5),
    rot('Neck', -6)
  ], rootOffsetX: 0, rootOffsetY: 1 },
  { timestamp: 1200, rotations: [
    rot('LeftArm', 45),
    rot('RightArm', -45),
    rot('Spine', 3),
    rot('Neck', -4)
  ], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 1800, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 }
];

// ========== TouchReaction 触摸回应(小幅惊吓,0.8s 单次) ==========

const TOUCH_REACTION_FRAMES: BonePoseFrame[] = [
  { timestamp: 0, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 200, rotations: [
    rot('LeftShoulder', -25),
    rot('RightShoulder', 25),
    rot('Neck', 8),
    rot('Head', 4)
  ], rootOffsetX: 0, rootOffsetY: -2 },
  { timestamp: 500, rotations: [
    rot('LeftShoulder', -12),
    rot('RightShoulder', 12),
    rot('Neck', 4)
  ], rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 800, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 }
];

// ========== Celebrate 庆祝(双臂高举,2.2s 单次) ==========

const CELEBRATE_FRAMES: BonePoseFrame[] = [
  { timestamp: 0, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 400, rotations: [
    rot('LeftShoulder', 150),
    rot('RightShoulder', -150)
  ], rootOffsetX: 0, rootOffsetY: -2 },
  { timestamp: 800, rotations: [
    rot('LeftShoulder', 165),
    rot('RightShoulder', -165)
  ], rootOffsetX: 0, rootOffsetY: -3 },
  { timestamp: 1200, rotations: [
    rot('LeftShoulder', 150),
    rot('RightShoulder', -150)
  ], rootOffsetX: 0, rootOffsetY: -2 },
  { timestamp: 1600, rotations: [
    rot('LeftShoulder', 165),
    rot('RightShoulder', -165)
  ], rootOffsetX: 0, rootOffsetY: -3 },
  { timestamp: 2000, rotations: [
    rot('LeftShoulder', 150),
    rot('RightShoulder', -150)
  ], rootOffsetX: 0, rootOffsetY: -2 },
  { timestamp: 2200, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 }
];

// ========== Apology 抱歉(鞠躬+双手合拢,1.5s 单次) ==========

const APOLOGY_FRAMES: BonePoseFrame[] = [
  { timestamp: 0, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 },
  { timestamp: 400, rotations: [
    rot('Spine', 10),
    rot('Neck', 8),
    rot('LeftShoulder', -35),
    rot('RightShoulder', 35),
    rot('LeftArm', 20),
    rot('RightArm', -20)
  ], rootOffsetX: 0, rootOffsetY: 4 },
  { timestamp: 1100, rotations: [
    rot('Spine', 10),
    rot('Neck', 8),
    rot('LeftShoulder', -35),
    rot('RightShoulder', 35),
    rot('LeftArm', 20),
    rot('RightArm', -20)
  ], rootOffsetX: 0, rootOffsetY: 4 },
  { timestamp: 1500, rotations: none(), rootOffsetX: 0, rootOffsetY: 0 }
];

// ========== 关键帧查找表 ==========

/**
 * 内置动作 ID → 关键帧列表。
 */
const ACTION_KEYFRAME_MAP: Record<string, BonePoseFrame[]> = {
  'builtin_idle': IDLE_FRAMES,
  'builtin_listening': LISTENING_FRAMES,
  'builtin_thinking': THINKING_FRAMES,
  'builtin_speaking': SPEAKING_FRAMES,
  'builtin_greeting': GREETING_FRAMES,
  'builtin_wave': WAVE_FRAMES,
  'builtin_nod': NOD_FRAMES,
  'builtin_shakehead': SHAKEHEAD_FRAMES,
  'builtin_happy': HAPPY_FRAMES,
  'builtin_confused': CONFUSED_FRAMES,
  'builtin_sad': SAD_FRAMES,
  'builtin_angry': ANGRY_FRAMES,
  'builtin_touchreaction': TOUCH_REACTION_FRAMES,
  'builtin_celebrate': CELEBRATE_FRAMES,
  'builtin_apology': APOLOGY_FRAMES
};

/**
 * 根据动作 ID 获取关键帧列表。
 * 未找到时回退到 Idle。
 */
export function getKeyframes(actionId: string): BonePoseFrame[] {
  const frames: BonePoseFrame[] | undefined = ACTION_KEYFRAME_MAP[actionId];
  if (frames !== undefined) {
    return frames;
  }
  return IDLE_FRAMES;
}

/**
 * 在关键帧之间进行线性插值,得到指定时刻的骨骼旋转。
 *
 * @param frames 关键帧列表(按 timestamp 升序)
 * @param timeMs 当前动画时间(毫秒)
 * @param duration 动作总时长(毫秒)
 * @param loop 是否循环
 * @returns 插值后的骨骼旋转增量和根偏移
 */
export function interpolateKeyframes(
  frames: BonePoseFrame[],
  timeMs: number,
  duration: number,
  loop: boolean
): BonePoseFrame {
  // 计算实际时间
  let t: number = timeMs;
  if (loop) {
    if (duration <= 0) {
      t = 0;
    } else {
      t = t % duration;
    }
  } else {
    if (t > duration) {
      t = duration;
    }
  }

  // 找到 t 所在的关键帧区间 [a, b]
  let a: BonePoseFrame = frames[0];
  let b: BonePoseFrame = frames[0];
  for (let i: number = 0; i < frames.length - 1; i++) {
    if (t >= frames[i].timestamp && t <= frames[i + 1].timestamp) {
      a = frames[i];
      b = frames[i + 1];
      break;
    }
  }
  if (t > frames[frames.length - 1].timestamp) {
    a = frames[frames.length - 1];
    b = frames[frames.length - 1];
  }

  // 计算插值因子
  const span: number = b.timestamp - a.timestamp;
  let k: number = 0;
  if (span > 0) {
    k = (t - a.timestamp) / span;
    if (k < 0) {
      k = 0;
    }
    if (k > 1) {
      k = 1;
    }
  }

  // 合并旋转列表(收集两帧中出现的所有骨骼名)
  const boneNames: string[] = [];
  collectBoneNames(a.rotations, boneNames);
  collectBoneNames(b.rotations, boneNames);

  // 对每个骨骼线性插值
  const resultRotations: BoneRotationEntry[] = [];
  for (let i: number = 0; i < boneNames.length; i++) {
    const name: string = boneNames[i];
    const angleA: number = findRotation(a.rotations, name);
    const angleB: number = findRotation(b.rotations, name);
    const angle: number = angleA + (angleB - angleA) * k;
    resultRotations.push({ bone: name, angle: angle });
  }

  // 根偏移插值
  const rootX: number = a.rootOffsetX + (b.rootOffsetX - a.rootOffsetX) * k;
  const rootY: number = a.rootOffsetY + (b.rootOffsetY - a.rootOffsetY) * k;

  return {
    timestamp: t,
    rotations: resultRotations,
    rootOffsetX: rootX,
    rootOffsetY: rootY
  };
}

/**
 * 收集旋转列表中的所有骨骼名(去重)。
 */
function collectBoneNames(rotations: BoneRotationEntry[], out: string[]): void {
  for (let i: number = 0; i < rotations.length; i++) {
    const name: string = rotations[i].bone;
    let found: boolean = false;
    for (let j: number = 0; j < out.length; j++) {
      if (out[j] === name) {
        found = true;
        break;
      }
    }
    if (!found) {
      out.push(name);
    }
  }
}

/**
 * 在旋转列表中查找指定骨骼的角度(未找到返回 0)。
 */
function findRotation(rotations: BoneRotationEntry[], boneName: string): number {
  for (let i: number = 0; i < rotations.length; i++) {
    if (rotations[i].bone === boneName) {
      return rotations[i].angle;
    }
  }
  return 0;
}
