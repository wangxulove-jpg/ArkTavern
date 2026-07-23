/**
 * Character3DActionSlot 标准动作槽位
 *
 * T-3D.6A: 定义统一动作语义槽位,独立于具体动画文件。
 *
 * 每个槽位代表"动作语义"而非具体动画文件名。
 * 例如:Idle 槽位可绑定 idle.anim、Idle_01、stand_loop 等动画。
 *
 * 槽位分类:
 * - 标准语义槽位(Idle/Thinking/Speaking/TouchReaction/情绪表达/社交动作)
 * - 自定义槽位(Custom01~Custom10):用户自由分配
 */

/**
 * 标准动作槽位枚举。
 */
export enum Character3DActionSlot {
  /** 待机(默认循环) */
  Idle = 'Idle',
  /** 思考中 */
  Thinking = 'Thinking',
  /** 说话中 */
  Speaking = 'Speaking',
  /** 触摸反应 */
  TouchReaction = 'TouchReaction',
  /** 开心 */
  Happy = 'Happy',
  /** 难过 */
  Sad = 'Sad',
  /** 生气 */
  Angry = 'Angry',
  /** 困惑 */
  Confused = 'Confused',
  /** 挥手 */
  Wave = 'Wave',
  /** 点头 */
  Nod = 'Nod',
  /** 摇头 */
  ShakeHead = 'ShakeHead',
  /** 问候 */
  Greeting = 'Greeting',
  /** 庆祝 */
  Celebrate = 'Celebrate',
  /** 自定义 01~10 */
  Custom01 = 'Custom01',
  Custom02 = 'Custom02',
  Custom03 = 'Custom03',
  Custom04 = 'Custom04',
  Custom05 = 'Custom05',
  Custom06 = 'Custom06',
  Custom07 = 'Custom07',
  Custom08 = 'Custom08',
  Custom09 = 'Custom09',
  Custom10 = 'Custom10'
}

/**
 * 槽位显示信息。
 */
export interface ActionSlotInfo {
  /** 槽位枚举值 */
  slot: Character3DActionSlot;
  /** 中文显示名 */
  displayName: string;
  /** 描述 */
  description: string;
  /** 是否默认循环(IdLE/Speaking/Thinking 等通常循环) */
  defaultLoop: boolean;
  /** 是否为自定义槽位 */
  isCustom: boolean;
}

/** 所有标准槽位列表(有序) */
const SLOT_INFOS: ActionSlotInfo[] = [
  { slot: Character3DActionSlot.Idle, displayName: '待机', description: '默认待机动作,通常循环播放', defaultLoop: true, isCustom: false },
  { slot: Character3DActionSlot.Thinking, displayName: '思考', description: '思考中动作', defaultLoop: true, isCustom: false },
  { slot: Character3DActionSlot.Speaking, displayName: '说话', description: '说话时动作', defaultLoop: true, isCustom: false },
  { slot: Character3DActionSlot.TouchReaction, displayName: '触摸反应', description: '被触摸时的反应动作', defaultLoop: false, isCustom: false },
  { slot: Character3DActionSlot.Happy, displayName: '开心', description: '开心情绪表达', defaultLoop: false, isCustom: false },
  { slot: Character3DActionSlot.Sad, displayName: '难过', description: '难过情绪表达', defaultLoop: false, isCustom: false },
  { slot: Character3DActionSlot.Angry, displayName: '生气', description: '生气情绪表达', defaultLoop: false, isCustom: false },
  { slot: Character3DActionSlot.Confused, displayName: '困惑', description: '困惑情绪表达', defaultLoop: false, isCustom: false },
  { slot: Character3DActionSlot.Wave, displayName: '挥手', description: '挥手致意', defaultLoop: false, isCustom: false },
  { slot: Character3DActionSlot.Nod, displayName: '点头', description: '点头确认', defaultLoop: false, isCustom: false },
  { slot: Character3DActionSlot.ShakeHead, displayName: '摇头', description: '摇头否定', defaultLoop: false, isCustom: false },
  { slot: Character3DActionSlot.Greeting, displayName: '问候', description: '问候动作', defaultLoop: false, isCustom: false },
  { slot: Character3DActionSlot.Celebrate, displayName: '庆祝', description: '庆祝动作', defaultLoop: false, isCustom: false },
  { slot: Character3DActionSlot.Custom01, displayName: '自定义 1', description: '用户自定义动作', defaultLoop: false, isCustom: true },
  { slot: Character3DActionSlot.Custom02, displayName: '自定义 2', description: '用户自定义动作', defaultLoop: false, isCustom: true },
  { slot: Character3DActionSlot.Custom03, displayName: '自定义 3', description: '用户自定义动作', defaultLoop: false, isCustom: true },
  { slot: Character3DActionSlot.Custom04, displayName: '自定义 4', description: '用户自定义动作', defaultLoop: false, isCustom: true },
  { slot: Character3DActionSlot.Custom05, displayName: '自定义 5', description: '用户自定义动作', defaultLoop: false, isCustom: true },
  { slot: Character3DActionSlot.Custom06, displayName: '自定义 6', description: '用户自定义动作', defaultLoop: false, isCustom: true },
  { slot: Character3DActionSlot.Custom07, displayName: '自定义 7', description: '用户自定义动作', defaultLoop: false, isCustom: true },
  { slot: Character3DActionSlot.Custom08, displayName: '自定义 8', description: '用户自定义动作', defaultLoop: false, isCustom: true },
  { slot: Character3DActionSlot.Custom09, displayName: '自定义 9', description: '用户自定义动作', defaultLoop: false, isCustom: true },
  { slot: Character3DActionSlot.Custom10, displayName: '自定义 10', description: '用户自定义动作', defaultLoop: false, isCustom: true }
];

/**
 * 获取所有标准槽位信息(有序列表)。
 */
export function getAllSlotInfos(): ActionSlotInfo[] {
  return SLOT_INFOS;
}

/**
 * 获取指定槽位的显示信息。
 */
export function getSlotInfo(slot: Character3DActionSlot): ActionSlotInfo {
  for (let i: number = 0; i < SLOT_INFOS.length; i++) {
    if (SLOT_INFOS[i].slot === slot) {
      return SLOT_INFOS[i];
    }
  }
  return { slot: slot, displayName: String(slot), description: '未知槽位', defaultLoop: false, isCustom: false };
}

/**
 * 将字符串安全转为槽位枚举。
 * 未知字符串返回 null。
 */
export function parseActionSlot(value: string): Character3DActionSlot | null {
  for (let i: number = 0; i < SLOT_INFOS.length; i++) {
    if (SLOT_INFOS[i].slot === value) {
      return SLOT_INFOS[i].slot;
    }
  }
  return null;
}

/**
 * 获取槽位的默认回退槽位(用于动作链回退)。
 * 例如:Speaking 回退到 Idle,TouchReaction 完成后回到 Idle。
 */
export function getFallbackSlot(slot: Character3DActionSlot): Character3DActionSlot {
  if (slot === Character3DActionSlot.Idle) {
    return Character3DActionSlot.Idle;
  }
  return Character3DActionSlot.Idle;
}
