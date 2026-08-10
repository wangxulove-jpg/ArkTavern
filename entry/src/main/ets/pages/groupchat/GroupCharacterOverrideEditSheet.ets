import { promptAction } from '@kit.ArkUI';
import { Character } from '../../models/Character';
import {
  GroupCharacterOverride,
  createOverride
} from '../../models/groupchat/GroupCharacterOverride';
import { ChatMessage, createChatMessage } from '../../models/ChatMessage';
import { ChatRole } from '../../models/ChatRole';
import { ChatRequest } from '../../models/ChatRequest';
import { ChatParticipant } from '../../models/ChatParticipant';
import { AppServices } from '../../services/AppServices';
import { generateUuid } from '../../utils/Uuid';
import { ThemePalette } from '../../theme/ThemePalette';

@Component
export struct GroupCharacterOverrideEditSheet {
  @Prop chatId: string = '';
  @Prop characterId: string = '';
  @Prop characterName: string = '';
  @State originalCharacter: Character | null = null;
  @State override: GroupCharacterOverride | null = null;
  @State isSaving: boolean = false;
  @State isOptimizing: boolean = false;
  @State optimizeError: string = '';
  @State nameText: string = '';
  @State descriptionText: string = '';
  @State personalityText: string = '';
  @State scenarioText: string = '';
  @State systemPromptText: string = '';
  @State mesExampleText: string = '';
  @State postHistoryInstructionsText: string = '';
  @State firstMessageText: string = '';

  @StorageProp('effectiveTheme') effectiveTheme: string = 'dark';

  aboutToAppear(): void {
    this.loadData();
  }

  async loadData(): Promise<void> {
    const charService = AppServices.getCharacterService();
    const overrideSvc = AppServices.getGroupCharacterOverrideService();

    try {
      this.originalCharacter = await charService.getById(this.characterId);
    } catch (_e) {
      this.originalCharacter = null;
    }

    try {
      this.override = await overrideSvc.getOverrides(this.chatId, this.characterId);
    } catch (_e) {
      this.override = null;
    }

    this.populateTextFromOverride();
  }

  populateTextFromOverride(): void {
    if (this.override !== null) {
      this.nameText = this.override.name !== null ? this.override.name : '';
      this.descriptionText = this.override.description !== null ? this.override.description : '';
      this.personalityText = this.override.personality !== null ? this.override.personality : '';
      this.scenarioText = this.override.scenario !== null ? this.override.scenario : '';
      this.systemPromptText = this.override.systemPrompt !== null ? this.override.systemPrompt : '';
      this.mesExampleText = this.override.mesExample !== null ? this.override.mesExample : '';
      this.postHistoryInstructionsText =
        this.override.postHistoryInstructions !== null ? this.override.postHistoryInstructions : '';
      this.firstMessageText = this.override.firstMessage !== null ? this.override.firstMessage : '';
    }
  }

  build(): void {
    Column() {
      Row() {
        Text('修改 ' + this.characterName + ' 设定')
          .fontSize($r('app.float.app_font_title'))
          .fontWeight(FontWeight.Bold)
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .layoutWeight(1)
        Button('取消')
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.saveAndClose();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 8, top: 16, bottom: 8 })
      .alignItems(VerticalAlign.Center)

      Text('留空则使用角色卡原始内容')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 4 })

      if (this.isOptimizing) {
        Row() {
          LoadingProgress().width(16).height(16).color(ThemePalette.accentColor(this.effectiveTheme))
          Text('AI 正在分析角色卡...').fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme)).margin({ left: 8 })
        }.width('100%').padding({ left: 16, right: 16, bottom: 8 })
      } else {
        Row() {
          Button('AI 优化设定')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor(ThemePalette.accentColor(this.effectiveTheme))
            .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
            .border({ width: 1, color: ThemePalette.accentColor(this.effectiveTheme), radius: $r('app.float.app_radius_sm') })
            .height(32).padding({ left: 12, right: 12 })
            .enabled(!this.isSaving)
            .onClick(() => { this.aiOptimize(); })
        }.width('100%').padding({ left: 16, right: 16, bottom: 4 })
      }

      if (this.optimizeError.length > 0) {
        Text(this.optimizeError).fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.world_error')).width('100%')
          .padding({ left: 16, right: 16, bottom: 4 })
      }

      Column() {
        Text('名称').fontSize($r('app.float.app_font_caption'))
          .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
          .width('100%').padding({ top: 8 })
        TextInput({ text: this.nameText, placeholder: this.originalCharacter !== null
          ? this.originalCharacter!.name : '角色名称' })
          .fontSize($r('app.float.app_font_body'))
          .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
          .placeholderColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
          .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .width('100%')
          .onChange((v: string) => { this.nameText = v; })
      }.width('100%').padding({ left: 16, right: 16 })

      Scroll() {
        Column() {
          this.editField('描述', this.descriptionText, this.originalCharacter !== null
            ? this.originalCharacter!.description : '', (v: string) => { this.descriptionText = v; })
          this.editField('性格', this.personalityText, this.originalCharacter !== null
            ? this.originalCharacter!.personality : '', (v: string) => { this.personalityText = v; })
          this.editField('场景/世界观', this.scenarioText, this.originalCharacter !== null
            ? this.originalCharacter!.scenario : '', (v: string) => { this.scenarioText = v; })
          this.editField('系统提示词', this.systemPromptText, this.originalCharacter !== null
            ? this.originalCharacter!.systemPrompt : '', (v: string) => { this.systemPromptText = v; })
          this.editField('对话示例', this.mesExampleText, this.originalCharacter !== null
            ? this.originalCharacter!.mesExample : '', (v: string) => { this.mesExampleText = v; })
          this.editField('后置指令', this.postHistoryInstructionsText, this.originalCharacter !== null
            ? this.originalCharacter!.postHistoryInstructions : '',
            (v: string) => { this.postHistoryInstructionsText = v; })
          this.editField('开场白', this.firstMessageText, this.originalCharacter !== null
            ? this.originalCharacter!.firstMessage : '', (v: string) => { this.firstMessageText = v; })
        }
        .padding({ left: 16, right: 16, bottom: 16 })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Auto)

      Row() {
        Button('恢复默认')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.world_error'))
          .backgroundColor(ThemePalette.surface2Color(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .enabled(!this.isSaving)
          .onClick(() => { this.reset(); })
        Button('保存')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_on_accent'))
          .backgroundColor(ThemePalette.accentColor(this.effectiveTheme))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .layoutWeight(1)
          .margin({ left: 8 })
          .enabled(!this.isSaving)
          .onClick(() => { this.saveAndClose(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(ThemePalette.pageBackgroundColor(this.effectiveTheme))
  }

  @Builder editField(label: string, value: string, placeholder: string, onChange: (v: string) => void): void {
    Column() {
      Text(label)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor(ThemePalette.textSecondaryColor(this.effectiveTheme))
        .width('100%')
        .padding({ top: 12, bottom: 4 })
      TextArea({ text: value, placeholder: placeholder.length > 0 ? placeholder : '（空）' })
        .fontSize($r('app.float.app_font_body'))
        .fontColor(ThemePalette.textPrimaryColor(this.effectiveTheme))
        .placeholderColor(ThemePalette.textTertiaryColor(this.effectiveTheme))
        .backgroundColor(ThemePalette.surface1Color(this.effectiveTheme))
        .borderRadius($r('app.float.app_radius_sm'))
        .width('100%')
        .constraintSize({ minHeight: 60, maxHeight: 200 })
        .onChange(onChange)
    }
    .width('100%')
  }

  private async aiOptimize(): Promise<void> {
    if (this.isOptimizing || this.isSaving) {
      return;
    }
    this.isOptimizing = true;
    this.optimizeError = '';
    try {
      const charService = AppServices.getCharacterService();
      const modelService = AppServices.getModelService();
      const groupSvc = AppServices.getGroupConversationPersistenceService();
      if (charService === null || modelService === null || groupSvc === null) {
        this.optimizeError = '服务未初始化';
        return;
      }

      const config = await modelService.getCurrentConfig();
      if (config === null) {
        this.optimizeError = '请先配置 AI Provider';
        return;
      }

      const participants: ChatParticipant[] = await groupSvc.getParticipants(this.chatId);
      const memberNames: string[] = [];
      const memberSummaries: string[] = [];
      for (let i = 0; i < participants.length; i++) {
        const p: ChatParticipant = participants[i];
        const c: Character | null = await charService.getById(p.characterId);
        if (c !== null) {
          memberNames.push(c.name);
          if (p.characterId === this.characterId) {
            memberSummaries.push(
              '★当前目标角色: ' + c.name + '\n' +
              (c.description.length > 0 ? '描述: ' + c.description.substring(0, 500) + '\n' : '') +
              (c.personality.length > 0 ? '性格: ' + c.personality.substring(0, 300) + '\n' : '') +
              (c.scenario.length > 0 ? '场景: ' + c.scenario.substring(0, 300) + '\n' : '')
            );
          } else {
            memberSummaries.push(
              '其他角色: ' + c.name +
              (c.description.length > 0 ? ' - ' + c.description.substring(0, 200) : '')
            );
          }
        }
      }

      const userPrompt: string =
        '你正在协助优化一个多人聊天中角色卡的设定。以下是群聊中所有角色:\n\n' +
        memberSummaries.join('\n\n') + '\n\n' +
        '请为目标角色(' + this.characterName + ')生成优化的设定覆盖,使其更自然地融入这个群聊。\n' +
        '根据其他角色的性格和设定,调整目标角色的描述、性格、场景/世界观、系统提示词、对话示例、后置指令。\n' +
        '输出仅包含以下 JSON 格式(不要添加额外文字):\n' +
        '{\n' +
        '  "description": "优化后的角色描述",\n' +
        '  "personality": "优化后的性格",\n' +
        '  "scenario": "优化后的场景/世界观",\n' +
        '  "systemPrompt": "优化后的系统提示词",\n' +
        '  "mesExample": "优化后的对话示例",\n' +
        '  "postHistoryInstructions": "优化后的后置指令"\n' +
        '}\n' +
        '每项单独一段话,用中文,不要修改名称和开场白,留空的字段保持为空。';

      const now: number = Date.now();
      const messages: ChatMessage[] = [
        createChatMessage('sys_opt', ChatRole.System,
          '你是一名角色设定优化师,擅长分析多个角色的互动关系,并优化角色卡的描述、性格和设定,使它们在同一场景中互动更自然流畅。',
          now),
        createChatMessage('user_opt', ChatRole.User, userPrompt, now + 1)
      ];

      const request: ChatRequest = {
        model: config.modelName,
        messages: messages,
        temperature: 0.7,
        topP: 0.9,
        maxTokens: 2048,
        stream: false
      };

      const response = await modelService.sendChat(request);
      const content: string = response.content;
      if (content === undefined || content.length === 0) {
        this.optimizeError = 'AI 返回为空, 请重试';
        return;
      }

      let jsonStr: string = content;
      const match = content.match(/\{[\s\S]*\}/);
      if (match !== null) {
        jsonStr = match[0];
      }
      const parsed: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;

      const desc: string = parsed['description'] as string ?? '';
      const pers: string = parsed['personality'] as string ?? '';
      const scen: string = parsed['scenario'] as string ?? '';
      const sys: string = parsed['systemPrompt'] as string ?? '';
      const mes: string = parsed['mesExample'] as string ?? '';
      const post: string = parsed['postHistoryInstructions'] as string ?? '';

      if (desc.length > 0) { this.descriptionText = desc; }
      if (pers.length > 0) { this.personalityText = pers; }
      if (scen.length > 0) { this.scenarioText = scen; }
      if (sys.length > 0) { this.systemPromptText = sys; }
      if (mes.length > 0) { this.mesExampleText = mes; }
      if (post.length > 0) { this.postHistoryInstructionsText = post; }

      promptAction.showToast({ message: 'AI 优化建议已填入, 请确认后保存', duration: 2000 });
    } catch (e) {
      this.optimizeError = 'AI 优化失败: ' + ((e as Error).message ?? '未知错误').substring(0, 50);
    } finally {
      this.isOptimizing = false;
    }
  }

  private async saveAndClose(): Promise<void> {
    if (this.isSaving) {
      return;
    }
    this.isSaving = true;
    try {
      const overrideSvc = AppServices.getGroupCharacterOverrideService();
      const hasContent: boolean =
        this.nameText.length > 0 || this.descriptionText.length > 0 ||
        this.personalityText.length > 0 || this.scenarioText.length > 0 ||
        this.systemPromptText.length > 0 || this.mesExampleText.length > 0 ||
        this.postHistoryInstructionsText.length > 0 || this.firstMessageText.length > 0;

      if (!hasContent) {
        await overrideSvc.deleteByGroupAndCharacter(this.chatId, this.characterId);
        return;
      }

      const now: number = Date.now();
      const override: GroupCharacterOverride = {
        id: this.override !== null ? this.override.id : 'gco_' + generateUuid(),
        groupConversationId: this.chatId,
        characterId: this.characterId,
        name: this.nameText.length > 0 ? this.nameText : null,
        description: this.descriptionText.length > 0 ? this.descriptionText : null,
        personality: this.personalityText.length > 0 ? this.personalityText : null,
        scenario: this.scenarioText.length > 0 ? this.scenarioText : null,
        systemPrompt: this.systemPromptText.length > 0 ? this.systemPromptText : null,
        mesExample: this.mesExampleText.length > 0 ? this.mesExampleText : null,
        postHistoryInstructions: this.postHistoryInstructionsText.length > 0
          ? this.postHistoryInstructionsText : null,
        firstMessage: this.firstMessageText.length > 0 ? this.firstMessageText : null,
        createdAt: this.override !== null ? this.override.createdAt : now,
        updatedAt: now
      };
      await overrideSvc.upsert(override);
      promptAction.showToast({ message: this.characterName + ' 设定已保存', duration: 1500 });
    } catch (e) {
      promptAction.showToast({ message: '保存失败', duration: 1500 });
    } finally {
      this.isSaving = false;
    }
  }

  private async reset(): Promise<void> {
    try {
      const overrideSvc = AppServices.getGroupCharacterOverrideService();
      await overrideSvc.deleteByGroupAndCharacter(this.chatId, this.characterId);
      this.nameText = '';
      this.descriptionText = '';
      this.personalityText = '';
      this.scenarioText = '';
      this.systemPromptText = '';
      this.mesExampleText = '';
      this.postHistoryInstructionsText = '';
      this.firstMessageText = '';
      this.override = null;
      promptAction.showToast({ message: '已恢复 ' + this.characterName + ' 默认设定', duration: 1500 });
    } catch (_e) {
      promptAction.showToast({ message: '重置失败', duration: 1500 });
    }
  }
}
