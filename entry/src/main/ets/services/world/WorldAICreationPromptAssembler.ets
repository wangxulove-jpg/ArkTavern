import { ChatMessage, createChatMessage } from '../../models/ChatMessage';
import { ChatRole } from '../../models/ChatRole';
import { ChatRequest } from '../../models/ChatRequest';
import { Character } from '../../models/Character';

const LOG_TAG: string = 'WorldAICreatePrompt';

export interface WorldAICreatePromptResult {
  readonly messages: ChatMessage[];
  readonly temperature: number;
  readonly maxTokens: number;
}

export class WorldAICreationPromptAssembler {
  buildPreviewPrompt(
    worldTheme: string,
    characters: Character[]
  ): WorldAICreatePromptResult {
    const characterCards: string = this.formatCharacterCards(characters);
    const themeLine: string = worldTheme.length > 0
      ? '世界主题/背景:' + worldTheme : '';

    const now: number = Date.now();
    const systemMsg: ChatMessage = createChatMessage(
      'sys_world_creator',
      ChatRole.System,
      '你是一名奇幻世界构建师,精通世界观设计、角色设定整合、地图制作。你擅长分析角色卡的背景故事、性格特征和能力设定,为角色们构建一个共存的、有深度的世界观。',
      now
    );

    const userContent: string =
      '请根据以下角色卡,创建一个让所有角色共存融洽的奇幻世界,输出结果仅包含以下 JSON 格式(不要添加额外文字):\n' +
      '{\n' +
      '  "world": {"name": "世界名称","description": "世界描述,说明世界观设定,让所有角色背景都能自然的融入这个世界"},\n' +
      '  "locations": [{"name": "地点名称","description": "结合角色背景设定的地点描述"}],\n' +
      '  "lorebook": [{"name": "条目名称","keys": ["触发","关键词"],"content": "详细世界观设定内容"}],\n' +
      '  "characterNotes": [{"characterId": "角色ID","worldRole": "该角色在世界中的定位","adaptation": "角色卡在该世界中的适配修改建议(仅为建议,不直接修改角色卡)"}]\n' +
      '}\n' +
      '- world.name 为中文,2-8 字\n' +
      '- world.description 需要结合所有角色卡信息,说明世界观、时代背景、势力分布、角色关系,让角色卡的主角和设定自然融入\n' +
      '- locations: 至少创建 2 个地点,结合角色卡的背景故事(如出生地、门派、阵营等)生成,每个地点有具体描述\n' +
      '- lorebook: 至少创建 3 条世界观条目,如时代背景、主要势力、传说故事、种族设定等,每条有触发关键词列表\n' +
      '- characterNotes: 为每个角色提供在世界中的定位和适配建议(仅建议,不修改角色卡本身)\n' +
      '- 所有字段内容为中文,描述详细但有层次感\n' +
      '\n' +
      (themeLine.length > 0 ? themeLine + '\n\n' : '') +
      '角色卡信息:\n' +
      characterCards;

    const userMsg: ChatMessage = createChatMessage(
      'user_world_create',
      ChatRole.User,
      userContent,
      now + 1
    );

    return {
      messages: [systemMsg, userMsg],
      temperature: 0.7,
      maxTokens: 4096
    };
  }

  private formatCharacterCards(characters: Character[]): string {
    const parts: string[] = [];
    for (let i = 0; i < characters.length; i++) {
      const c: Character = characters[i];
      const desc: string = c.description.length > 300
        ? c.description.substring(0, 300) + '...' : c.description;
      const personality: string = c.personality.length > 200
        ? c.personality.substring(0, 200) + '...' : c.personality;
      const scenario: string = c.scenario.length > 300
        ? c.scenario.substring(0, 300) + '...' : c.scenario;
      const sysPrompt: string = c.systemPrompt.length > 300
        ? c.systemPrompt.substring(0, 300) + '...' : c.systemPrompt;
      const mesEx: string = c.mesExample.length > 200
        ? c.mesExample.substring(0, 200) + '...' : c.mesExample;

      const card: string =
        '--- 角色' + (i + 1).toString() + ': ' + c.id + ' ---\n' +
        '名称:' + c.name + '\n' +
        (desc.length > 0 ? '描述:' + desc + '\n' : '') +
        (personality.length > 0 ? '性格:' + personality + '\n' : '') +
        (scenario.length > 0 ? '场景/背景:' + scenario + '\n' : '') +
        (sysPrompt.length > 0 ? '系统提示词:' + sysPrompt + '\n' : '') +
        (mesEx.length > 0 ? '对话示例:' + mesEx + '\n' : '');
      parts.push(card);
    }
    return parts.join('\n\n');
  }
}
