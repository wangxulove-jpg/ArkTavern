/**
 * MultiPersonPromptBuilder 多人世界 Prompt 构建器
 *
 * 职责:
 * - 构建包含 15 部分的多人世界 system prompt
 * - 注入候选角色的可见记忆(基于 visibility 规则)
 * - 注入候选角色与用户的关系
 * - 注入候选角色之间的关系
 * - 约定结构化 JSON 输出格式
 *
 * 不负责:
 * - 模型请求(由 MultiPersonChatService 发送)
 * - 历史消息裁剪(由 HistoryTrimmer 处理)
 *
 * 规则:
 * - 角色只能注入:公共事实、当前场景、自己的私人记忆、自己参与/目击/被告知的事件
 * - 禁止注入其他角色的私人秘密和内心评价
 * - 不让角色冒充其他角色
 * - 不让离场角色参与
 */

import { ChatMessage } from '../models/ChatMessage';
import { ChatRole } from '../models/ChatRole';
import { World, WorldUserIdentity } from '../models/World';
import { WorldMember } from '../models/WorldMember';
import { WorldScene } from '../models/WorldScene';
import { WorldReplyMode } from '../models/World';
import { Character } from '../models/Character';
import {
  CharacterUserRelationship,
  CharacterRelationship
} from '../models/WorldRelationship';
import { WorldMemoryEvent, WorldPrivateMemory } from '../models/WorldMemory';
import { SpeakerCandidate } from './SpeakerScheduler';
import { createChatMessage } from '../models/ChatMessage';

/**
 * 多人 Prompt 构建输入。
 */
export interface MultiPersonPromptInput {
  readonly world: World;
  readonly userIdentity: WorldUserIdentity;
  readonly scene: WorldScene | null;
  readonly presentMembers: WorldMember[];
  readonly candidateCharacters: Character[];
  readonly candidateMembers: WorldMember[];
  readonly userRelationships: Map<string, CharacterUserRelationship>;
  readonly characterRelationships: Map<string, CharacterRelationship>;
  readonly candidateMemories: Map<string, WorldMemoryEvent[]>;
  readonly candidatePrivateMemories: Map<string, WorldPrivateMemory[]>;
  readonly sceneMemories: WorldMemoryEvent[];
  readonly publicMemories: WorldMemoryEvent[];
  readonly recentMessages: ChatMessage[];
  readonly userMessage: string;
  readonly replyMode: WorldReplyMode;
  readonly candidates: SpeakerCandidate[];
  readonly allowedCharacterIds: string[];
}

/**
 * 多人 Prompt 构建结果。
 */
export interface MultiPersonPromptResult {
  readonly messages: ChatMessage[];
  readonly systemPrompt: string;
  readonly userPrompt: string;
}

/**
 * 单角色生成 Prompt 输入(新架构:本地确定发言角色,模型只生成该角色正文)。
 */
export interface SingleCharacterPromptInput {
  readonly world: World;
  readonly userIdentity: WorldUserIdentity;
  readonly scene: WorldScene | null;
  /** 当前唯一发言角色 */
  readonly character: Character;
  /** 当前角色对应的 WorldMember */
  readonly member: WorldMember;
  /** 在场成员(用于让当前角色知道谁在场) */
  readonly presentMembers: WorldMember[];
  /** 在场角色卡(用于让当前角色识别其他角色) */
  readonly presentCharacters: Character[];
  /** 当前角色与用户的关系 */
  readonly userRelationship: CharacterUserRelationship | null;
  /** 当前角色与其他在场角色的关系 */
  readonly characterRelationships: Map<string, CharacterRelationship>;
  /** 当前角色可见的公共/场景/事件记忆 */
  readonly visibleEvents: WorldMemoryEvent[];
  /** 当前角色私人记忆 */
  readonly privateMemories: WorldPrivateMemory[];
  /** 最近群聊消息(已包含本轮用户消息和本轮前面角色的回复) */
  readonly recentMessages: ChatMessage[];
  /** 用户本轮输入 */
  readonly userMessage: string;
  /** 本轮之前已成功生成的角色消息(同轮上下文) */
  readonly sameRoundPreviousMessages: ChatMessage[];
}

/**
 * 旁白生成 Prompt 输入。
 */
export interface NarratorPromptInput {
  readonly world: World;
  readonly userIdentity: WorldUserIdentity;
  readonly scene: WorldScene | null;
  readonly presentMembers: WorldMember[];
  readonly presentCharacters: Character[];
  readonly publicMemories: WorldMemoryEvent[];
  readonly sceneMemories: WorldMemoryEvent[];
  readonly recentMessages: ChatMessage[];
  readonly userMessage: string;
}

/** 单角色生成输出格式约定:只输出该角色正文,不输出角色名/JSON/解释 */
function buildSingleCharacterOutputSpec(characterName: string): string {
  return `# 输出格式(强制)

你只能扮演 ${characterName} 这一个角色,只输出该角色的回复正文。

## 必须遵守

- 只输出 ${characterName} 的发言正文
- 不得输出角色名前缀(如 "${characterName}: ")
- 不得输出 JSON 对象、Markdown 代码块标记
- 不得输出"好的/以下是"等解释性文字
- 不得输出其他角色的发言
- 不得替用户说话、思考或决定行动
- 不得使用其他角色不知道的私人信息
- 不得直接读取其他角色的内心想法

## 输出示例

用户输入:"你好啊"
正确输出(只输出正文):
你好,很高兴见到你。我刚到这儿,这里的气氛真不错。

错误输出(严禁):
${characterName}: 你好,很高兴见到你。
\`\`\`json
{"content":"你好"}
\`\`\`
(其他角色名): 嗯,我也觉得。
好的,这是${characterName}的回复:你好

再次强调:回复的第一个字符必须是角色正文,不得包含角色名、JSON、代码块或任何解释。`;
}

/** 旁白生成输出格式约定:只输出旁白正文 */
const NARRATOR_OUTPUT_SPEC: string =
`# 输出格式(强制)

你只能输出场景旁白/环境描述的正文,不输出任何角色发言。

## 必须遵守

- 只输出场景描述、环境变化、时间流转、氛围渲染
- 不得输出任何角色发言(不输出角色名、对白)
- 不得输出 JSON 对象、Markdown 代码块标记
- 不得输出"好的/以下是"等解释性文字
- 不得替用户说话或决定行动
- 简洁生动,通常 2-5 句即可

## 输出示例

用户输入:"大家走进酒馆"
正确输出(只输出旁白正文):
酒馆的木门吱呀一声被推开,暖黄的灯光从屋内溢出,空气中飘着烤面包和麦酒的香气。炉火噼啪作响,几个顾客抬起头看向门口,随即又各自低声交谈起来。

错误输出(严禁):
\`\`\`json
{"description":"酒馆的门被推开"}
\`\`\`
好的,这是旁白:酒馆的门被推开
酒馆老板: 欢迎光临!

再次强调:回复只包含场景描述正文,不包含角色发言、JSON、代码块或解释。`;

/** 旧架构输出格式约定(保留仅用于兼容诊断,不再作为正常生成主流程) */
const OUTPUT_FORMAT_SPEC: string =
`# 输出格式(强制)

你以"角色扮演文本"格式输出,每条消息占一段(段落之间用空行分隔)。

## 段落格式

1. 角色发言(两种写法皆可):
   - 「角色名: 对白内容」(冒号分隔,推荐)
   - 「(角色名 动作描述) 对白内容」(括号内写动作,括号外写对白)
2. 旁白/场景描述:
   - 「——旁白内容」(以破折号开头)
   - 「旁白: 内容」(显式标记)
3. 多条消息之间用空行分隔。

## 约束

- 每段必须以"角色名:"或"(角色名"或"——"开头
- 角色名必须使用候选角色列表中的名字(可用 ID 或名称)
- 离场或静音角色不得发言
- 不替用户说话、思考或决定行动
- 不让角色冒充其他角色
- 不让角色使用自己不知道的信息
- 不直接读取其他角色的私人心理
- 关系变化必须有明确事件依据
- 普通寒暄不得频繁改变关系
- 不输出 Markdown 代码块标记
- 不输出"好的/以下是"等解释性文字

## 输出示例

用户输入:"你好啊"
正确输出:
艾伦: 你好,很高兴见到你。

用户输入:"大家介绍一下自己"
正确输出:
艾伦: 我是艾伦,来自帕拉迪岛。
莉莉: (小声)我是莉莉...
——房间里弥漫着淡淡的香气。

错误输出(严禁):
\`\`\`json
{"messages":[...]}
\`\`\`
好的,这是回复:艾伦: 你好
（无角色名的纯文本段落)

再次强调:每段必须以"角色名:"或"(角色名"或"——"开头,段落之间用空行分隔。`;

/**
 * 多人 Prompt 构建器。
 * 不依赖外部服务,纯函数构建。
 */
export class MultiPersonPromptBuilder {
  /**
   * 构建单角色生成请求的 messages 数组(新架构主流程)。
   *
   * 只注入当前角色有权看到的上下文,要求模型只输出该角色正文。
   * 返回 [System, ...recentMessages, ...sameRoundPrevious, User] 顺序。
   */
  buildSingleCharacterPrompt(input: SingleCharacterPromptInput): MultiPersonPromptResult {
    const systemParts: string[] = [];
    systemParts.push(`# 你正在扮演:${input.character.name}`);
    systemParts.push('');
    // 1. 世界背景
    systemParts.push('## 1. 世界背景');
    systemParts.push(input.world.background.length > 0 ? input.world.background : '(无)');
    systemParts.push('');
    // 2. 当前场景
    systemParts.push('## 2. 当前场景');
    systemParts.push(this.formatScene(input.scene));
    systemParts.push('');
    // 3. 你扮演的角色
    systemParts.push('## 3. 你扮演的角色');
    systemParts.push(this.formatSingleCharacter(input.character, input.member));
    systemParts.push('');
    // 4. 在场其他角色
    systemParts.push('## 4. 在场其他角色');
    systemParts.push(this.formatOtherPresentCharacters(input.presentCharacters, input.character.id));
    systemParts.push('');
    // 5. 用户身份
    systemParts.push('## 5. 用户身份');
    systemParts.push(this.formatUserIdentity(input.userIdentity));
    systemParts.push('');
    // 6. 你对用户的称呼
    systemParts.push('## 6. 你对用户的称呼');
    systemParts.push(this.formatSelfAddressTerm(input.member, input.userRelationship));
    systemParts.push('');
    // 7. 你与用户的关系
    systemParts.push('## 7. 你与用户的关系');
    systemParts.push(this.formatSelfUserRelationship(input.userRelationship));
    systemParts.push('');
    // 8. 你与其他在场角色的关系
    systemParts.push('## 8. 你与其他在场角色的关系');
    systemParts.push(this.formatSelfCharacterRelationships(
      input.character.id, input.presentCharacters, input.characterRelationships
    ));
    systemParts.push('');
    // 9. 你的可见记忆
    systemParts.push('## 9. 你的可见记忆(公共/场景/事件)');
    systemParts.push(this.formatPublicMemories(input.visibleEvents));
    systemParts.push('');
    // 10. 你的私人记忆
    systemParts.push('## 10. 你的私人记忆');
    systemParts.push(this.formatPrivateMemoriesList(input.privateMemories));
    systemParts.push('');
    // 输出格式
    systemParts.push('## 输出格式');
    systemParts.push(buildSingleCharacterOutputSpec(input.character.name));

    const systemPrompt: string = systemParts.join('\n');
    const userPrompt: string = input.userMessage;

    // 消息顺序:System → 历史消息 → 同轮前序消息 → 用户本轮输入
    const messages: ChatMessage[] = [
      createChatMessage(generateSimpleId(), ChatRole.System, systemPrompt, Date.now()),
      ...input.recentMessages,
      ...input.sameRoundPreviousMessages,
      createChatMessage(generateSimpleId(), ChatRole.User, userPrompt, Date.now())
    ];

    return {
      messages: messages,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt
    };
  }

  /**
   * 构建旁白生成请求的 messages 数组。
   */
  buildNarratorPrompt(input: NarratorPromptInput): MultiPersonPromptResult {
    const systemParts: string[] = [];
    systemParts.push('# 你正在生成场景旁白');
    systemParts.push('');
    // 1. 世界背景
    systemParts.push('## 1. 世界背景');
    systemParts.push(input.world.background.length > 0 ? input.world.background : '(无)');
    systemParts.push('');
    // 2. 当前场景
    systemParts.push('## 2. 当前场景');
    systemParts.push(this.formatScene(input.scene));
    systemParts.push('');
    // 3. 在场角色
    systemParts.push('## 3. 在场角色');
    systemParts.push(this.formatPresentCharactersList(input.presentCharacters));
    systemParts.push('');
    // 4. 用户身份
    systemParts.push('## 4. 用户身份');
    systemParts.push(this.formatUserIdentity(input.userIdentity));
    systemParts.push('');
    // 5. 公共记忆
    systemParts.push('## 5. 公共记忆');
    systemParts.push(this.formatPublicMemories(input.publicMemories));
    systemParts.push('');
    // 6. 场景记忆
    systemParts.push('## 6. 场景记忆');
    systemParts.push(this.formatSceneMemories(input.sceneMemories));
    systemParts.push('');
    // 输出格式
    systemParts.push('## 输出格式');
    systemParts.push(NARRATOR_OUTPUT_SPEC);

    const systemPrompt: string = systemParts.join('\n');
    const userPrompt: string = input.userMessage;

    const messages: ChatMessage[] = [
      createChatMessage(generateSimpleId(), ChatRole.System, systemPrompt, Date.now()),
      ...input.recentMessages,
      createChatMessage(generateSimpleId(), ChatRole.User, userPrompt, Date.now())
    ];

    return {
      messages: messages,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt
    };
  }

  /**
   * 旧架构构建方法(保留仅用于兼容诊断,不再作为正常生成主流程)。
   */
  build(input: MultiPersonPromptInput): MultiPersonPromptResult {
    const systemParts: string[] = [];
    systemParts.push('# 多人世界设定');
    systemParts.push('');
    // 1. 世界背景
    systemParts.push('## 1. 世界背景');
    systemParts.push(input.world.background.length > 0 ? input.world.background : '(无)');
    systemParts.push('');
    // 2. 用户在世界中的身份
    systemParts.push('## 2. 用户在世界中的身份');
    systemParts.push(this.formatUserIdentity(input.userIdentity));
    systemParts.push('');
    // 3. 当前场景
    systemParts.push('## 3. 当前场景');
    systemParts.push(this.formatScene(input.scene));
    systemParts.push('');
    // 4. 在场角色
    systemParts.push('## 4. 在场角色');
    systemParts.push(this.formatPresentMembers(input.presentMembers));
    systemParts.push('');
    // 5. 候选角色卡
    systemParts.push('## 5. 候选角色卡');
    systemParts.push(this.formatCandidateCharacters(input.candidateCharacters, input.candidateMembers));
    systemParts.push('');
    // 6. 每个角色对用户的称呼
    systemParts.push('## 6. 候选角色对用户的称呼');
    systemParts.push(this.formatAddressTerms(input.candidateMembers, input.userRelationships));
    systemParts.push('');
    // 7. 世界公共记忆
    systemParts.push('## 7. 世界公共记忆');
    systemParts.push(this.formatPublicMemories(input.publicMemories));
    systemParts.push('');
    // 8. 当前场景记忆
    systemParts.push('## 8. 当前场景记忆');
    systemParts.push(this.formatSceneMemories(input.sceneMemories));
    systemParts.push('');
    // 9. 候选角色私人记忆
    systemParts.push('## 9. 候选角色私人记忆');
    systemParts.push(this.formatPrivateMemories(input.candidatePrivateMemories));
    systemParts.push('');
    // 10. 角色与用户的关系
    systemParts.push('## 10. 候选角色与用户的关系');
    systemParts.push(this.formatUserRelationships(input.candidateMembers, input.userRelationships));
    systemParts.push('');
    // 11. 角色之间的关系
    systemParts.push('## 11. 候选角色之间的关系');
    systemParts.push(this.formatCharacterRelationships(input.candidateMembers, input.characterRelationships));
    systemParts.push('');
    // 14. 当前回复模式
    systemParts.push('## 14. 当前回复模式');
    systemParts.push(this.formatReplyMode(input.replyMode, input.candidates));
    systemParts.push('');
    // 15. 允许发言的角色 ID
    systemParts.push('## 15. 允许发言的角色 ID');
    systemParts.push(input.allowedCharacterIds.join(', '));
    systemParts.push('');
    // 16. 候选角色名映射(供输出时引用)
    systemParts.push('## 16. 候选角色名映射');
    systemParts.push(this.formatCharacterNameMap(input.candidateCharacters));
    systemParts.push('');
    // 输出格式
    systemParts.push('## 输出格式');
    systemParts.push(OUTPUT_FORMAT_SPEC);

    const systemPrompt: string = systemParts.join('\n');
    // 13. 用户本轮输入(作为 user 消息)
    const userPrompt: string = input.userMessage;

    const messages: ChatMessage[] = [
      createChatMessage(generateSimpleId(), ChatRole.System, systemPrompt, Date.now()),
      ...input.recentMessages,
      createChatMessage(generateSimpleId(), ChatRole.User, userPrompt, Date.now())
    ];

    return {
      messages: messages,
      systemPrompt: systemPrompt,
      userPrompt: userPrompt
    };
  }

  private formatUserIdentity(identity: WorldUserIdentity): string {
    const parts: string[] = [];
    parts.push(`- 用户名称: ${identity.userName.length > 0 ? identity.userName : '(未设置)'}`);
    if (identity.identityDescription.length > 0) {
      parts.push(`- 身份描述: ${identity.identityDescription}`);
    }
    if (identity.appearance.length > 0) {
      parts.push(`- 外貌特征: ${identity.appearance}`);
    }
    if (identity.background.length > 0) {
      parts.push(`- 世界背景: ${identity.background}`);
    }
    if (identity.publicInfo.length > 0) {
      parts.push(`- 公开信息: ${identity.publicInfo}`);
    }
    if (identity.privateInfo.length > 0) {
      parts.push(`- 私人信息: (仅角色私下知晓,不向其他角色公开)`);
    }
    if (identity.defaultAddressTerm.length > 0) {
      parts.push(`- 默认称呼: ${identity.defaultAddressTerm}`);
    }
    return parts.length > 0 ? parts.join('\n') : '(无)';
  }

  private formatScene(scene: WorldScene | null): string {
    if (scene === null) {
      return '(无)';
    }
    const parts: string[] = [];
    parts.push(`- 场景名称: ${scene.name}`);
    if (scene.location.length > 0) {
      parts.push(`- 地点: ${scene.location}`);
    }
    if (scene.timeDescription.length > 0) {
      parts.push(`- 时间: ${scene.timeDescription}`);
    }
    if (scene.description.length > 0) {
      parts.push(`- 描述: ${scene.description}`);
    }
    if (scene.presentCharacterIds.length > 0) {
      parts.push(`- 在场角色: ${scene.presentCharacterIds.join(', ')}`);
    }
    if (scene.importantObjects.length > 0) {
      parts.push(`- 重要物品: ${scene.importantObjects.join(', ')}`);
    }
    return parts.join('\n');
  }

  private formatPresentMembers(members: WorldMember[]): string {
    if (members.length === 0) {
      return '(无)';
    }
    return members.map((m: WorldMember) =>
      `- ${m.characterId} (活跃度=${m.talkativeness.toFixed(2)}${m.muted ? ',静音' : ''})`
    ).join('\n');
  }

  private formatCandidateCharacters(
    characters: Character[],
    members: WorldMember[]
  ): string {
    if (characters.length === 0) {
      return '(无)';
    }
    const parts: string[] = [];
    for (let i = 0; i < characters.length; i++) {
      const ch: Character = characters[i];
      const m: WorldMember | undefined = members.find(
        (mm: WorldMember) => mm.characterId === ch.id
      );
      parts.push(`### 角色 ${ch.id}`);
      parts.push(`- 名称: ${ch.name}`);
      if (ch.description.length > 0) {
        parts.push(`- 描述: ${ch.description}`);
      }
      if (ch.personality.length > 0) {
        parts.push(`- 性格: ${ch.personality}`);
      }
      if (ch.scenario.length > 0) {
        parts.push(`- 场景设定: ${ch.scenario}`);
      }
      if (ch.systemPrompt.length > 0) {
        parts.push(`- 系统提示: ${ch.systemPrompt}`);
      }
      if (m !== undefined && m.initialRelationship.relationshipLabel.length > 0) {
        parts.push(`- 初始关系: ${m.initialRelationship.relationshipLabel}`);
      }
      parts.push('');
    }
    return parts.join('\n');
  }

  private formatAddressTerms(
    members: WorldMember[],
    userRelationships: Map<string, CharacterUserRelationship>
  ): string {
    if (members.length === 0) {
      return '(无)';
    }
    const parts: string[] = [];
    for (let i = 0; i < members.length; i++) {
      const m: WorldMember = members[i];
      const rel: CharacterUserRelationship | undefined = userRelationships.get(m.characterId);
      const term: string = rel !== undefined && rel.userNameOverride.length > 0
        ? rel.userNameOverride
        : m.initialRelationship.addressTerm;
      parts.push(`- ${m.characterId} 称呼用户: ${term.length > 0 ? term : '(默认)'}`);
    }
    return parts.join('\n');
  }

  private formatPublicMemories(memories: WorldMemoryEvent[]): string {
    if (memories.length === 0) {
      return '(无)';
    }
    return memories.map((m: WorldMemoryEvent) => `- ${m.summary}`).join('\n');
  }

  private formatSceneMemories(memories: WorldMemoryEvent[]): string {
    if (memories.length === 0) {
      return '(无)';
    }
    return memories.map((m: WorldMemoryEvent) => `- ${m.summary}`).join('\n');
  }

  private formatPrivateMemories(
    candidatePrivateMemories: Map<string, WorldPrivateMemory[]>
  ): string {
    if (candidatePrivateMemories.size === 0) {
      return '(无)';
    }
    const parts: string[] = [];
    candidatePrivateMemories.forEach((mems: WorldPrivateMemory[], characterId: string) => {
      if (mems.length === 0) {
        return;
      }
      parts.push(`### 角色 ${characterId} 的私人记忆`);
      for (let i = 0; i < mems.length; i++) {
        parts.push(`- ${mems[i].summary}`);
      }
      parts.push('');
    });
    return parts.length > 0 ? parts.join('\n') : '(无)';
  }

  private formatUserRelationships(
    members: WorldMember[],
    userRelationships: Map<string, CharacterUserRelationship>
  ): string {
    if (members.length === 0) {
      return '(无)';
    }
    const parts: string[] = [];
    for (let i = 0; i < members.length; i++) {
      const m: WorldMember = members[i];
      const rel: CharacterUserRelationship | undefined = userRelationships.get(m.characterId);
      if (rel === undefined) {
        parts.push(`- ${m.characterId}: (无关系记录)`);
        continue;
      }
      parts.push(`### 角色 ${m.characterId} 对用户`);
      parts.push(`- 关系称谓: ${rel.relationshipLabel}`);
      parts.push(`- 好感(affinity): ${rel.affinity}`);
      parts.push(`- 信任(trust): ${rel.trust}`);
      parts.push(`- 尊重(respect): ${rel.respect}`);
      parts.push(`- 恐惧(fear): ${rel.fear}`);
      parts.push(`- 敌意(hostility): ${rel.hostility}`);
      parts.push(`- 依赖(dependency): ${rel.dependency}`);
      parts.push(`- 熟悉(familiarity): ${rel.familiarity}`);
      if (rel.currentEmotion.length > 0) {
        parts.push(`- 当前情绪: ${rel.currentEmotion}`);
      }
      if (rel.sharedExperiences.length > 0) {
        parts.push(`- 共同经历: ${rel.sharedExperiences.join('; ')}`);
      }
      if (rel.promises.length > 0) {
        parts.push(`- 承诺: ${rel.promises.join('; ')}`);
      }
      if (rel.conflicts.length > 0) {
        parts.push(`- 冲突: ${rel.conflicts.join('; ')}`);
      }
      // 不输出 privateOpinion / secretsFromUser / secretsSharedByUser
      parts.push('');
    }
    return parts.length > 0 ? parts.join('\n') : '(无)';
  }

  private formatCharacterRelationships(
    members: WorldMember[],
    characterRelationships: Map<string, CharacterRelationship>
  ): string {
    if (members.length === 0) {
      return '(无)';
    }
    const parts: string[] = [];
    for (let i = 0; i < members.length; i++) {
      const src: WorldMember = members[i];
      for (let j = 0; j < members.length; j++) {
        const tgt: WorldMember = members[j];
        if (src.characterId === tgt.characterId) {
          continue;
        }
        const key: string = relKey(src.characterId, tgt.characterId);
        const rel: CharacterRelationship | undefined = characterRelationships.get(key);
        if (rel === undefined) {
          continue;
        }
        parts.push(`### 角色 ${src.characterId} 对角色 ${tgt.characterId}`);
        parts.push(`- 关系称谓: ${rel.relationshipLabel}`);
        parts.push(`- 信任(trust): ${rel.trust}`);
        parts.push(`- 好感(affinity): ${rel.affinity}`);
        parts.push(`- 敌意(hostility): ${rel.hostility}`);
        if (rel.currentEmotion.length > 0) {
          parts.push(`- 当前情绪: ${rel.currentEmotion}`);
        }
        if (rel.sharedExperiences.length > 0) {
          parts.push(`- 共同经历: ${rel.sharedExperiences.join('; ')}`);
        }
        parts.push('');
      }
    }
    return parts.length > 0 ? parts.join('\n') : '(无)';
  }

  private formatReplyMode(mode: WorldReplyMode, candidates: SpeakerCandidate[]): string {
    switch (mode) {
      case 'designated':
        return '指定角色:仅允许用户指定的角色发言。';
      case 'auto_director': {
        const ids: string = candidates.map((c: SpeakerCandidate) => c.characterId).join(', ');
        return `自动导演:从候选角色中选择 1-2 位发言。候选: ${ids}`;
      }
      case 'all_respond':
        return '全员回应:所有在场且未静音的角色依次回应。';
      case 'narrator_only':
        return '仅旁白:只生成场景描述,角色不发言。';
      default:
        return '(未知)';
    }
  }

  /**
   * 输出"角色名 = ID"映射表,让模型在输出 RP 文本时引用正确的角色名。
   */
  private formatCharacterNameMap(characters: Character[]): string {
    if (characters.length === 0) {
      return '(无)';
    }
    return characters.map((c: Character) => `- ${c.name} = ${c.id}`).join('\n');
  }

  /**
   * 输出当前角色完整角色卡(新架构单角色生成使用)。
   */
  private formatSingleCharacter(character: Character, member: WorldMember): string {
    const parts: string[] = [];
    parts.push(`- 名称: ${character.name}`);
    parts.push(`- ID: ${character.id}`);
    if (character.description.length > 0) {
      parts.push(`- 描述: ${character.description}`);
    }
    if (character.personality.length > 0) {
      parts.push(`- 性格: ${character.personality}`);
    }
    if (character.scenario.length > 0) {
      parts.push(`- 场景设定: ${character.scenario}`);
    }
    if (character.systemPrompt.length > 0) {
      parts.push(`- 系统提示: ${character.systemPrompt}`);
    }
    if (character.mesExample.length > 0) {
      parts.push(`- 对话示例: ${character.mesExample}`);
    }
    if (member.initialRelationship.relationshipLabel.length > 0) {
      parts.push(`- 初始关系: ${member.initialRelationship.relationshipLabel}`);
    }
    parts.push(`- 活跃度(talkativeness): ${member.talkativeness.toFixed(2)}`);
    return parts.join('\n');
  }

  /**
   * 输出在场其他角色简要列表(新架构单角色生成使用)。
   * 只列出名称和简短描述,不暴露其他角色私人记忆/关系。
   */
  private formatOtherPresentCharacters(characters: Character[], selfId: string): string {
    const others: Character[] = characters.filter((c: Character) => c.id !== selfId);
    if (others.length === 0) {
      return '(无其他角色)';
    }
    const parts: string[] = [];
    for (let i = 0; i < others.length; i++) {
      const c: Character = others[i];
      let line: string = `- ${c.name} (ID: ${c.id})`;
      if (c.description.length > 0) {
        const descLen: number = Math.min(60, c.description.length);
        line += ` - ${c.description.substring(0, descLen)}`;
      }
      parts.push(line);
    }
    return parts.join('\n');
  }

  /**
   * 输出当前角色对用户的称呼(新架构使用)。
   */
  private formatSelfAddressTerm(
    member: WorldMember,
    userRelationship: CharacterUserRelationship | null
  ): string {
    const term: string = userRelationship !== null && userRelationship.userNameOverride.length > 0
      ? userRelationship.userNameOverride
      : member.initialRelationship.addressTerm;
    return term.length > 0 ? term : '(默认)';
  }

  /**
   * 输出当前角色与用户的关系(新架构使用,只暴露当前角色有权知道的信息)。
   */
  private formatSelfUserRelationship(rel: CharacterUserRelationship | null): string {
    if (rel === null) {
      return '(无关系记录)';
    }
    const parts: string[] = [];
    parts.push(`- 关系称谓: ${rel.relationshipLabel}`);
    parts.push(`- 好感(affinity): ${rel.affinity}`);
    parts.push(`- 信任(trust): ${rel.trust}`);
    parts.push(`- 尊重(respect): ${rel.respect}`);
    parts.push(`- 恐惧(fear): ${rel.fear}`);
    parts.push(`- 敌意(hostility): ${rel.hostility}`);
    parts.push(`- 依赖(dependency): ${rel.dependency}`);
    parts.push(`- 熟悉(familiarity): ${rel.familiarity}`);
    if (rel.currentEmotion.length > 0) {
      parts.push(`- 当前情绪: ${rel.currentEmotion}`);
    }
    if (rel.sharedExperiences.length > 0) {
      parts.push(`- 共同经历: ${rel.sharedExperiences.join('; ')}`);
    }
    if (rel.promises.length > 0) {
      parts.push(`- 承诺: ${rel.promises.join('; ')}`);
    }
    if (rel.conflicts.length > 0) {
      parts.push(`- 冲突: ${rel.conflicts.join('; ')}`);
    }
    return parts.join('\n');
  }

  /**
   * 输出当前角色与其他在场角色的关系(新架构使用)。
   */
  private formatSelfCharacterRelationships(
    selfId: string,
    presentCharacters: Character[],
    characterRelationships: Map<string, CharacterRelationship>
  ): string {
    const parts: string[] = [];
    for (let i = 0; i < presentCharacters.length; i++) {
      const other: Character = presentCharacters[i];
      if (other.id === selfId) {
        continue;
      }
      const key: string = selfId + '>' + other.id;
      const rel: CharacterRelationship | undefined = characterRelationships.get(key);
      if (rel === undefined) {
        continue;
      }
      parts.push(`### 你对 ${other.name}`);
      parts.push(`- 关系称谓: ${rel.relationshipLabel}`);
      parts.push(`- 信任(trust): ${rel.trust}`);
      parts.push(`- 好感(affinity): ${rel.affinity}`);
      parts.push(`- 敌意(hostility): ${rel.hostility}`);
      if (rel.currentEmotion.length > 0) {
        parts.push(`- 当前情绪: ${rel.currentEmotion}`);
      }
      if (rel.sharedExperiences.length > 0) {
        parts.push(`- 共同经历: ${rel.sharedExperiences.join('; ')}`);
      }
      parts.push('');
    }
    return parts.length > 0 ? parts.join('\n') : '(无)';
  }

  /**
   * 输出私人记忆列表(新架构使用)。
   */
  private formatPrivateMemoriesList(memories: WorldPrivateMemory[]): string {
    if (memories.length === 0) {
      return '(无)';
    }
    return memories.map((m: WorldPrivateMemory) => `- ${m.summary}`).join('\n');
  }

  /**
   * 输出在场角色列表(新架构旁白生成使用)。
   */
  private formatPresentCharactersList(characters: Character[]): string {
    if (characters.length === 0) {
      return '(无)';
    }
    return characters.map((c: Character) => `- ${c.name} (ID: ${c.id})`).join('\n');
  }
}

function relKey(sourceId: string, targetId: string): string {
  return sourceId + '>' + targetId;
}

/**
 * 简单 ID 生成器(仅用于内部 system/user 消息 ID)。
 * 不持久化到数据库,只在请求时使用。
 */
function generateSimpleId(): string {
  return 'mp-' + Date.now().toString(36) + '-' + Math.floor(Math.random() * 1000000).toString(36);
}
