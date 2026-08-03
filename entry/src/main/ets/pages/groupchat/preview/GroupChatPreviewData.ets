/**
 * GroupChatPreviewData 多人聊天静态预览数据
 *
 * G-UI-1 阶段专用:纯静态预览角色与示例文案。
 * 不读取数据库,不调用角色 Service。
 *
 * 删除条件:G-DATA-1 接入真实角色数据后,PREVIEW_CHARACTERS 改为从
 * CharacterService 读取,本文件中仅保留示例消息文案或整体删除。
 */

import {
  GroupChatPreviewCharacter,
  GroupChatPreviewMember,
  GroupChatPreviewMessage,
  GroupChatPreviewSession,
  GroupMemberPreviewStatus,
  GroupRoundPreviewStatus,
  GroupReplyMode,
  GroupFailurePolicy
} from './GroupChatPreviewModels';

/** 预览角色池(创建群聊时从此池选择) */
export const PREVIEW_CHARACTERS: readonly GroupChatPreviewCharacter[] = [
  { id: 'preview_char_alice', name: '艾莉丝', description: '旅店冒险者,擅长风系魔法', avatarUri: '' },
  { id: 'preview_char_kane', name: '凯恩', description: '退役佣兵,沉默寡言的剑士', avatarUri: '' },
  { id: 'preview_char_mia', name: '米娅', description: '旅店吟游诗人,性格活泼', avatarUri: '' },
  { id: 'preview_char_lina', name: '莉娜', description: '魔法研究室学徒,专注炼金术', avatarUri: '' },
  { id: 'preview_char_professor', name: '教授', description: '魔法研究室导师,严谨理性', avatarUri: '' },
  { id: 'preview_char_keeper', name: '酒馆老板', description: '旅店老板,见多识广', avatarUri: '' },
  { id: 'preview_char_aron', name: '阿隆', description: '流浪商队护卫,精明务实', avatarUri: '' },
  { id: 'preview_char_nia', name: '妮娅', description: '森林精灵猎手,警觉敏锐', avatarUri: '' }
];

/** 预览角色上限(与创建页限制一致) */
export const PREVIEW_MEMBER_MIN: number = 2;
export const PREVIEW_MEMBER_MAX: number = 8;

/**
 * 构建一个预览成员。
 * order 从 0 开始,status 默认 Waiting,enabled 默认 true。
 */
export function buildPreviewMember(
  character: GroupChatPreviewCharacter,
  order: number,
  status: GroupMemberPreviewStatus = GroupMemberPreviewStatus.Waiting,
  enabled: boolean = true
): GroupChatPreviewMember {
  return {
    id: 'member_' + character.id + '_' + String(order),
    characterId: character.id,
    name: character.name,
    avatarUri: character.avatarUri,
    order: order,
    status: status,
    enabled: enabled
  };
}

/** 构建一条预览消息 */
export function buildPreviewMessage(
  id: string,
  senderKind: 'user' | 'character',
  senderCharacterId: string,
  senderName: string,
  avatarUri: string,
  content: string,
  status: string,
  createdAt: number
): GroupChatPreviewMessage {
  return {
    id: id,
    senderKind: senderKind,
    senderCharacterId: senderCharacterId,
    senderName: senderName,
    avatarUri: avatarUri,
    content: content,
    status: status,
    createdAt: createdAt,
    updatedAt: createdAt
  };
}

/**
 * 生成默认群聊名称(角色名组合)。
 * 2 人:A、B
 * 3 人:A、B 与 C
 * 4+ 人:A、B、C 等 N 位角色
 */
export function composeDefaultTitle(names: string[]): string {
  const n: number = names.length;
  if (n === 0) {
    return '新群聊';
  }
  if (n === 1) {
    return names[0];
  }
  if (n === 2) {
    return names[0] + '、' + names[1];
  }
  if (n === 3) {
    return names[0] + '、' + names[1] + ' 与 ' + names[2];
  }
  return names[0] + '、' + names[1] + '、' + names[2] + ' 等 ' + String(n) + ' 位角色';
}

/** 获取预览角色 by id */
export function getPreviewCharacterById(id: string): GroupChatPreviewCharacter | null {
  for (let i = 0; i < PREVIEW_CHARACTERS.length; i++) {
    if (PREVIEW_CHARACTERS[i].id === id) {
      return PREVIEW_CHARACTERS[i];
    }
  }
  return null;
}

/** 示例回复文案(按角色 id 索引,模拟顺序回复内容) */
const SAMPLE_REPLIES: Record<string, string> = {
  'preview_char_alice': '嗯,听起来不错。我刚从城外回来,正好想喝点热的。老板,来一杯蜂蜜酒怎么样?',
  'preview_char_kane': '……随便。我不挑。只要不是那种甜得发腻的就行。',
  'preview_char_mia': '哇,我也想喝!凯恩你别老皱着眉头嘛,今天难得大家都在,开心点嘛~',
  'preview_char_lina': '等一下,我先把这个反应记完……好了。你们在说什么?酒?我也可以来一杯。',
  'preview_char_professor': '适度即可。莉娜,你明天还有实验,别喝太多。',
  'preview_char_keeper': '哈哈哈,都坐都坐。今天大厅不忙,我亲自给你们倒。蜂蜜酒两杯,再来一壶清茶。',
  'preview_char_aron': '商队明天一早出发,我就不喝了,来碗热汤就行。老板,有羊肉汤吗?',
  'preview_char_nia': '森林里最近不太安静,我顺路过来歇脚。给我一杯温水就好,谢谢。'
};

/** 获取示例回复文案,无匹配时返回通用文案 */
export function getSampleReply(characterId: string): string {
  const text: string | undefined = SAMPLE_REPLIES[characterId];
  if (text !== undefined) {
    return text;
  }
  return '好的,我听到了。';
}

/**
 * 构建初始示例群聊(首页展示用)。
 * 包含两个预览群聊:旅店大厅(有消息)、魔法研究室(无消息)。
 */
export function buildSeedPreviewSessions(): GroupChatPreviewSession[] {
  const now: number = Date.now();

  // 群聊 1:旅店大厅(3 人,有 4 条消息,本轮已完成)
  const alice: GroupChatPreviewCharacter = PREVIEW_CHARACTERS[0];
  const kane: GroupChatPreviewCharacter = PREVIEW_CHARACTERS[1];
  const mia: GroupChatPreviewCharacter = PREVIEW_CHARACTERS[2];
  const tavernMembers: GroupChatPreviewMember[] = [
    buildPreviewMember(alice, 0, GroupMemberPreviewStatus.Completed, true),
    buildPreviewMember(kane, 1, GroupMemberPreviewStatus.Completed, true),
    buildPreviewMember(mia, 2, GroupMemberPreviewStatus.Completed, true)
  ];
  const tavernMessages: GroupChatPreviewMessage[] = [
    buildPreviewMessage('seed_msg_1', 'user', '', '你', '', '大家晚上好,今晚有什么打算?', 'completed', now - 600000),
    buildPreviewMessage('seed_msg_2', 'character', alice.id, alice.name, alice.avatarUri, getSampleReply(alice.id), 'completed', now - 540000),
    buildPreviewMessage('seed_msg_3', 'character', kane.id, kane.name, kane.avatarUri, getSampleReply(kane.id), 'completed', now - 480000),
    buildPreviewMessage('seed_msg_4', 'character', mia.id, mia.name, mia.avatarUri, getSampleReply(mia.id), 'completed', now - 420000)
  ];

  // 群聊 2:魔法研究室(2 人,无消息)
  const lina: GroupChatPreviewCharacter = PREVIEW_CHARACTERS[3];
  const professor: GroupChatPreviewCharacter = PREVIEW_CHARACTERS[4];
  const labMembers: GroupChatPreviewMember[] = [
    buildPreviewMember(lina, 0, GroupMemberPreviewStatus.Waiting, true),
    buildPreviewMember(professor, 1, GroupMemberPreviewStatus.Waiting, true)
  ];

  return [
    {
      id: 'seed_session_tavern',
      title: '旅店大厅',
      members: tavernMembers,
      messages: tavernMessages,
      roundStatus: GroupRoundPreviewStatus.Idle,
      currentGeneratingOrder: -1,
      completedCount: 0,
      totalCount: 3,
      replyMode: GroupReplyMode.Sequential,
      failurePolicy: GroupFailurePolicy.StopRound,
      updatedAt: now - 420000
    },
    {
      id: 'seed_session_lab',
      title: '魔法研究室',
      members: labMembers,
      messages: [],
      roundStatus: GroupRoundPreviewStatus.Idle,
      currentGeneratingOrder: -1,
      completedCount: 0,
      totalCount: 2,
      replyMode: GroupReplyMode.Sequential,
      failurePolicy: GroupFailurePolicy.StopRound,
      updatedAt: now - 3600000
    }
  ];
}
