import { WorldStateService } from '../../services/world/WorldStateService';
import { CharacterService } from '../../services/CharacterService';
import { ModelService } from '../../services/ModelService';
import { ProviderConfig } from '../../models/ProviderConfig';
import { ChatRequest } from '../../models/ChatRequest';
import { ChatResponse } from '../../models/ChatResponse';
import { Character } from '../../models/Character';
import { ChatMessage } from '../../models/ChatMessage';
import { World } from '../../models/world/World';
import { WorldLocation } from '../../models/world/WorldLocation';
import { WorldAICreationPromptAssembler, WorldAICreatePromptResult } from '../../services/world/WorldAICreationPromptAssembler';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldAICreateVM';

export interface SelectedCharacterItem {
  readonly character: Character;
  readonly selected: boolean;
}

export interface AiGeneratedWorldPreview {
  worldName: string;
  worldDescription: string;
  locations: AiGeneratedLocation[];
  lorebookEntries: AiGeneratedLorebookEntry[];
  characterNotes: AiGeneratedCharacterNote[];
  rawJson: string;
}

export interface AiGeneratedLocation {
  name: string;
  description: string;
}

export interface AiGeneratedLorebookEntry {
  name: string;
  keys: string[];
  content: string;
}

export interface AiGeneratedCharacterNote {
  characterId: string;
  worldRole: string;
  adaptation: string;
}

export enum WorldAICreateStage {
  SelectCharacters,
  InputTheme,
  Generating,
  Review
}

export class WorldAICreateViewModel {
  private readonly stateService: WorldStateService;
  private readonly characterService: CharacterService;
  private readonly modelService: ModelService;
  private readonly promptAssembler: WorldAICreationPromptAssembler;

  stage: WorldAICreateStage = WorldAICreateStage.SelectCharacters;
  characters: SelectedCharacterItem[] = [];
  worldTheme: string = '';
  isGenerating: boolean = false;
  generationError: string = '';
  preview: AiGeneratedWorldPreview | null = null;
  isSaving: boolean = false;
  saveError: string = '';
  saveSucceeded: boolean = false;
  playerDisplayName: string = '';
  playerNameError: string = '';

  private disposed: boolean = false;

  constructor(
    stateService: WorldStateService,
    characterService: CharacterService,
    modelService: ModelService
  ) {
    this.stateService = stateService;
    this.characterService = characterService;
    this.modelService = modelService;
    this.promptAssembler = new WorldAICreationPromptAssembler();
  }

  async loadCharacters(): Promise<void> {
    try {
      const all: Character[] = await this.characterService.list();
      this.characters = all.map((c: Character): SelectedCharacterItem => {
        return { character: c, selected: false };
      });
    } catch (e) {
      Logger.warn(LOG_TAG, 'loadCharacters failed: ' + String(e));
    }
  }

  toggleCharacter(index: number): void {
    if (index < 0 || index >= this.characters.length) {
      return;
    }
    const item: SelectedCharacterItem = this.characters[index];
    this.characters[index] = { character: item.character, selected: !item.selected };
    this.characters = [...this.characters];
  }

  get selectedCount(): number {
    let count: number = 0;
    for (let i = 0; i < this.characters.length; i++) {
      if (this.characters[i].selected) {
        count = count + 1;
      }
    }
    return count;
  }

  get selectedCharacters(): Character[] {
    const result: Character[] = [];
    for (let i = 0; i < this.characters.length; i++) {
      if (this.characters[i].selected) {
        result.push(this.characters[i].character);
      }
    }
    return result;
  }

  canGenerate(): boolean {
    return this.selectedCount >= 1 && !this.isGenerating;
  }

  goToThemeInput(): void {
    if (this.selectedCount < 2) {
      return;
    }
    this.stage = WorldAICreateStage.InputTheme;
  }

  goBackToSelect(): void {
    this.stage = WorldAICreateStage.SelectCharacters;
    this.generationError = '';
  }

  async generateWorld(): Promise<void> {
    if (this.isGenerating || this.disposed) {
      return;
    }
    if (this.selectedCount < 1) {
      this.generationError = '请至少选择 1 个角色';
      return;
    }

    this.isGenerating = true;
    this.generationError = '';
    this.stage = WorldAICreateStage.Generating;

    try {
      const config: ProviderConfig | null = await this.modelService.getCurrentConfig();
      if (config === null) {
        this.generationError = '请先配置 AI Provider';
        this.stage = WorldAICreateStage.InputTheme;
        this.isGenerating = false;
        return;
      }

      const prompt: WorldAICreatePromptResult = this.promptAssembler.buildPreviewPrompt(
        this.worldTheme.trim(), this.selectedCharacters
      );

      const request: ChatRequest = {
        model: config.modelName,
        messages: prompt.messages,
        temperature: prompt.temperature,
        topP: 0.9,
        maxTokens: prompt.maxTokens,
        stream: false
      };

      const startTime: number = Date.now();
      const response: ChatResponse = await this.modelService.sendChat(request);
      if (this.disposed) {
        return;
      }

      const elapsed: number = Date.now() - startTime;
      Logger.info(LOG_TAG, 'AI response received in ' + elapsed.toString() + 'ms, contentLen=' +
        response.content.length.toString());

      const content: string = response.content;
      if (content === undefined || content.length === 0) {
        this.generationError = 'AI 返回为空, 请确认 Provider 配置正确且角色卡内容未超出 Token 限制';
        this.stage = WorldAICreateStage.InputTheme;
        this.isGenerating = false;
        return;
      }

      this.preview = this.parseResponse(content, this.selectedCharacters);
      if (this.preview === null) {
        this.generationError = 'AI 返回格式异常, 请重试(JSON 解析失败)';
        this.stage = WorldAICreateStage.InputTheme;
        this.isGenerating = false;
        return;
      }

      this.stage = WorldAICreateStage.Review;
      this.isGenerating = false;
    } catch (e) {
      Logger.error(LOG_TAG, 'generateWorld failed: ' + (e as Error).message);
      this.generationError = 'AI 请求失败: ' + this.safeError(e);
      this.stage = WorldAICreateStage.InputTheme;
      this.isGenerating = false;
    }
  }

  cancelGeneration(): void {
    // sendChat 不支持取消,设置 disposed 让回调忽略结果
    // 实际取消需通过 ChatStreamHandle.abort()
  }

  private parseResponse(content: string, characters: Character[]): AiGeneratedWorldPreview | null {
    let jsonStr: string = content;
    const jsonMatch: RegExpMatchArray | null = content.match(/\{[\s\S]*\}/);
    if (jsonMatch !== null) {
      jsonStr = jsonMatch[0];
    }
    try {
      const parsed: Record<string, Object> = JSON.parse(jsonStr) as Record<string, Object>;

      const worldObj: Record<string, Object> | undefined =
        parsed['world'] as Record<string, Object> | undefined;
      const worldName: string = worldObj !== undefined
        ? (worldObj['name'] as string ?? 'AI 世界') : 'AI 世界';
      const worldDesc: string = worldObj !== undefined
        ? (worldObj['description'] as string ?? '') : '';

      const locsRaw: Object[] | undefined = parsed['locations'] as Object[] | undefined;
      const locations: AiGeneratedLocation[] = [];
      if (locsRaw !== undefined && Array.isArray(locsRaw)) {
        for (let i = 0; i < locsRaw.length; i++) {
          const l: Record<string, Object> = locsRaw[i] as Record<string, Object>;
          locations.push({
            name: l['name'] as string ?? '地点' + (i + 1).toString(),
            description: l['description'] as string ?? ''
          });
        }
      }

      const lbRaw: Object[] | undefined = parsed['lorebook'] as Object[] | undefined;
      const lorebookEntries: AiGeneratedLorebookEntry[] = [];
      if (lbRaw !== undefined && Array.isArray(lbRaw)) {
        for (let i = 0; i < lbRaw.length; i++) {
          const lb: Record<string, Object> = lbRaw[i] as Record<string, Object>;
          const keysRaw: Object = lb['keys'];
          const keys: string[] = [];
          if (keysRaw !== undefined && Array.isArray(keysRaw)) {
            for (let k = 0; k < (keysRaw as Object[]).length; k++) {
              keys.push(String((keysRaw as Object[])[k]));
            }
          }
          lorebookEntries.push({
            name: lb['name'] as string ?? '世界观条目' + (i + 1).toString(),
            keys: keys,
            content: lb['content'] as string ?? ''
          });
        }
      }

      const notesRaw: Object[] | undefined = parsed['characterNotes'] as Object[] | undefined;
      const characterNotes: AiGeneratedCharacterNote[] = [];
      if (notesRaw !== undefined && Array.isArray(notesRaw)) {
        for (let i = 0; i < notesRaw.length; i++) {
          const n: Record<string, Object> = notesRaw[i] as Record<string, Object>;
          const charId: string = n['characterId'] as string ?? '';
          if (charId.length === 0) {
            continue;
          }
          characterNotes.push({
            characterId: charId,
            worldRole: n['worldRole'] as string ?? '',
            adaptation: n['adaptation'] as string ?? ''
          });
        }
      }

      return {
        worldName: worldName,
        worldDescription: worldDesc,
        locations: locations,
        lorebookEntries: lorebookEntries,
        characterNotes: characterNotes,
        rawJson: jsonStr
      };
    } catch (e) {
      Logger.error(LOG_TAG, 'parseResponse failed: ' + (e as Error).message);
      return null;
    }
  }

  async saveWorld(): Promise<void> {
    if (this.isSaving || this.preview === null || this.disposed) {
      return;
    }
    const playerName: string = this.playerDisplayName.trim();
    if (playerName.length === 0) {
      this.playerNameError = '请输入玩家名称';
      return;
    }
    this.playerNameError = '';
    this.isSaving = true;
    this.saveError = '';

    try {
      const p: AiGeneratedWorldPreview = this.preview;
      const world: World = await this.stateService.createWorld(
        p.worldName,
        p.worldDescription,
        playerName
      );

      for (let i = 0; i < p.locations.length; i++) {
        const loc: AiGeneratedLocation = p.locations[i];
        await this.stateService.createLocation(world.id, loc.name, loc.description);
      }

      const selected: Character[] = this.selectedCharacters;
      for (let i = 0; i < selected.length; i++) {
        await this.stateService.addCharacterToWorld(world.id, selected[i].id, undefined);
      }

      if (this.disposed) {
        return;
      }
      this.saveSucceeded = true;
    } catch (e) {
      Logger.error(LOG_TAG, 'saveWorld failed: ' + (e as Error).message);
      this.saveError = '创建失败:' + this.safeError(e);
    } finally {
      this.isSaving = false;
    }
  }

  dispose(): void {
    this.disposed = true;
  }

  private safeError(e: Object): string {
    const msg: string = (e as Error).message ?? '未知错误';
    return msg.length > 80 ? msg.substring(0, 80) : msg;
  }
}
