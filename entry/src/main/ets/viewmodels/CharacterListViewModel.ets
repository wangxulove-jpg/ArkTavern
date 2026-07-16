/**
 * CharacterListViewModel 角色列表页面状态管理
 *
 * 角色列表页面的唯一 ViewModel,管理角色 CRUD 和当前角色选择。
 * 不直接操作 CharacterStore 或 Preferences。
 */

import { Character, CharacterUpdates } from '../models/Character';
import { CharacterService } from '../services/CharacterService';
import { ParsedCharacterCard } from '../parser/CharacterCardJsonParser';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'CharacterListViewModel';

@Observed
export class CharacterListViewModel {
  characters: Character[] = [];
  currentCharacterId: string | null = null;
  loading: boolean = false;
  /** 错误提示 */
  errorMessage: string = '';
  /** 编辑对话框状态 */
  showEditDialog: boolean = false;
  editingCharacter: Character | null = null;
  /** 编辑表单字段 */
  editName: string = '';
  editDescription: string = '';
  editPersonality: string = '';
  editScenario: string = '';
  editFirstMessage: string = '';
  editSystemPrompt: string = '';
  /** 删除确认 */
  deleteTarget: Character | null = null;
  /** 导入预览 */
  showImportPreview: boolean = false;
  previewCard: ParsedCharacterCard | null = null;
  importJsonBuffer: string = '';
  importing: boolean = false;
  importError: string = '';
  /** 导出 */
  exporting: boolean = false;
  exportError: string = '';

  private readonly service: CharacterService;

  constructor(service: CharacterService) {
    this.service = service;
  }

  async load(): Promise<void> {
    this.loading = true;
    this.errorMessage = '';
    try {
      this.characters = await this.service.list();
      this.currentCharacterId = await this.service.getCurrentCharacterId();
    } catch (e) {
      this.errorMessage = '加载角色列表失败';
      Logger.error(LOG_TAG, 'load failed: ' + String(e));
    } finally {
      this.loading = false;
    }
  }

  /** 打开新建对话框 */
  showNewDialog(): void {
    this.editingCharacter = null;
    this.editName = '';
    this.editDescription = '';
    this.editPersonality = '';
    this.editScenario = '';
    this.editFirstMessage = '';
    this.editSystemPrompt = '';
    this.showEditDialog = true;
  }

  /** 打开编辑对话框 */
  showEditDialogFor(character: Character): void {
    this.editingCharacter = character;
    this.editName = character.name;
    this.editDescription = character.description;
    this.editPersonality = character.personality;
    this.editScenario = character.scenario;
    this.editFirstMessage = character.firstMessage;
    this.editSystemPrompt = character.systemPrompt;
    this.showEditDialog = true;
  }

  /** 关闭编辑对话框 */
  closeEditDialog(): void {
    this.showEditDialog = false;
    this.editingCharacter = null;
  }

  /** 保存(新建或编辑) */
  async saveEdit(): Promise<boolean> {
    this.errorMessage = '';
    if (this.editName.trim().length === 0) {
      this.errorMessage = '角色名称不能为空';
      return false;
    }
    try {
      if (this.editingCharacter === null) {
        // 新建
        await this.service.create(
          this.editName, this.editDescription, this.editPersonality,
          this.editScenario, this.editFirstMessage, this.editSystemPrompt
        );
      } else {
        // 编辑
        await this.service.update(this.editingCharacter.id, {
          name: this.editName,
          description: this.editDescription,
          personality: this.editPersonality,
          scenario: this.editScenario,
          firstMessage: this.editFirstMessage,
          systemPrompt: this.editSystemPrompt
        });
      }
      this.showEditDialog = false;
      this.editingCharacter = null;
      await this.load();
      return true;
    } catch (e) {
      this.errorMessage = '保存失败: ' + String(e);
      Logger.error(LOG_TAG, 'saveEdit failed: ' + String(e));
      return false;
    }
  }

  /** 删除角色 */
  async deleteCharacter(id: string): Promise<void> {
    this.errorMessage = '';
    try {
      await this.service.remove(id);
      await this.load();
    } catch (e) {
      this.errorMessage = '删除失败: ' + String(e);
      Logger.error(LOG_TAG, 'deleteCharacter failed: ' + String(e));
    }
  }

  /** 设为当前角色 */
  async setCurrent(id: string | null): Promise<void> {
    this.errorMessage = '';
    try {
      await this.service.setCurrentCharacterId(id);
      this.currentCharacterId = await this.service.getCurrentCharacterId();
    } catch (e) {
      this.errorMessage = '设置失败: ' + String(e);
      Logger.error(LOG_TAG, 'setCurrent failed: ' + String(e));
    }
  }

  /** 是否为当前角色 */
  isCurrent(character: Character): boolean {
    return this.currentCharacterId === character.id;
  }

  // ===== 导入导出 =====

  /**
   * 从文件 URI 读取并解析角色卡,显示预览。
   * 页面调用此方法后,检查 showImportPreview 以显示预览对话框。
   *
   * @param uri 文件 URI
   */
  async startImportFile(uri: string): Promise<void> {
    this.importing = true;
    this.importError = '';
    this.previewCard = null;
    this.importJsonBuffer = '';
    this.showImportPreview = false;
    try {
      const jsonString: string = await this.service.readFileContent(uri);
      const result = this.service.parseCharacterJson(jsonString);
      if (!result.success || result.card === null) {
        this.importError = result.error !== null ? result.error : '导入失败';
        return;
      }
      this.previewCard = result.card;
      this.importJsonBuffer = jsonString;
      this.showImportPreview = true;
    } catch (e) {
      this.importError = '导入失败: ' + String(e);
      Logger.error(LOG_TAG, 'startImportFile failed: ' + String(e));
    } finally {
      this.importing = false;
    }
  }

  /**
   * 确认导入:保存预览中的角色卡。
   * 导入成功后刷新列表,但不自动设为当前角色。
   */
  async confirmImport(): Promise<void> {
    if (this.previewCard === null) {
      return;
    }
    this.importing = true;
    this.importError = '';
    try {
      await this.service.importFromParsed(this.previewCard);
      this.showImportPreview = false;
      this.previewCard = null;
      this.importJsonBuffer = '';
      await this.load();
    } catch (e) {
      this.importError = '保存失败: ' + String(e);
      Logger.error(LOG_TAG, 'confirmImport failed: ' + String(e));
    } finally {
      this.importing = false;
    }
  }

  /**
   * 取消导入预览。
   */
  cancelImport(): void {
    this.showImportPreview = false;
    this.previewCard = null;
    this.importJsonBuffer = '';
    this.importError = '';
  }

  /**
   * 导出角色到文件 URI。
   *
   * @param id 角色 ID
   * @param uri 文件 URI
   */
  async exportToFile(id: string, uri: string): Promise<void> {
    this.exporting = true;
    this.exportError = '';
    try {
      await this.service.exportToFile(id, uri);
    } catch (e) {
      this.exportError = '导出失败: ' + String(e);
      Logger.error(LOG_TAG, 'exportToFile failed: ' + String(e));
      throw new Error(String(e));
    } finally {
      this.exporting = false;
    }
  }
}