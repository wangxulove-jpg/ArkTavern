/**
 * GroupNarrationPromptAssembler 多人旁白 Prompt 组装器(GROUP-NARRATION-1A)
 */

import { ChatMessage } from '../../models/ChatMessage';
import { ChatRole } from '../../models/ChatRole';

const NARRATION_MAX_TOKENS: number = 256;

export interface GroupNarrationPromptInput {
  readonly groupTitle: string;
  readonly userMessage: string;
  readonly speakerName: string;
  readonly speakerReply: string;
  readonly otherCharacterSummaries: string[];
}

export interface GroupNarrationPromptResult {
  readonly messages: ChatMessage[];
  readonly maxTokens: number;
}

export function buildNarrationPrompt(input: GroupNarrationPromptInput): GroupNarrationPromptResult {
  const otherCharsText: string = input.otherCharacterSummaries.length > 0
    ? input.otherCharacterSummaries.join('\n')
    : '无其他在场角色';

  const systemPrompt: string =
    '你是群聊场景旁白。\n' +
    '只描述除当前对话角色和用户之外的其他在场角色的动作、表情、' +
    '视线、姿态或无声反应。\n' +
    '不要替任何角色长篇发言。\n' +
    '不要替用户行动、发言或思考。\n' +
    '不要推进未给出的世界事件。\n' +
    '只输出旁白正文，不输出 JSON、标题或解释。';

  const userPrompt: string =
    '群聊：' + input.groupTitle + '\n' +
    '用户说：' + input.userMessage + '\n' +
    input.speakerName + '回复：' + input.speakerReply + '\n\n' +
    '其他在场角色：\n' + otherCharsText;

  const systemMessage: ChatMessage = {
    id: 'narration_system',
    role: ChatRole.System,
    content: systemPrompt,
    createdAt: 0
  };

  const userMessage: ChatMessage = {
    id: 'narration_user',
    role: ChatRole.User,
    content: userPrompt,
    createdAt: 0
  };

  return {
    messages: [systemMessage, userMessage],
    maxTokens: NARRATION_MAX_TOKENS
  };
}
