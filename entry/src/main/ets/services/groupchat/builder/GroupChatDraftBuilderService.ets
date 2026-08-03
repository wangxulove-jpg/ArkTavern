/**
 * GroupChatDraftBuilderService AI 建群草案生成服务(G-AI-BUILDER-1)
 *
 * 职责:
 * - 构建受控 Builder Prompt(System + User,只含角色别名与安全摘要)
 * - 调用 ModelService.streamChatWithConfig(使用生成开始时的配置快照)
 * - 累计模型响应
 * - 解析结构化 JSON 结果
 * - 本地验证(成员数量 / 别名归属 / 去重 / 角色仍存在)
 * - 一次受控修复尝试
 * - 取消当前生成
 *
 * 不依赖:Page / ArkUI / 数据库写入。
 * 不直接调用:GroupConversationPersistenceService.createGroupConversation。
 *
 * 安全:
 * - 不发送 Character ID / systemPrompt / mesExample / 头像路径 / 创建时间
 * - 模型只看到别名(C1/C2/...)与受控摘要
 * - alias→characterId 映射在本地完成,不信任模型返回的任意 ID
 * - 日志不记录完整 Prompt / 角色摘要全文 / 原始响应
 *
 * 取消与迟到回调:
 * - 独立 operationId,不复用 GroupRuntimeRegistry
 * - cancel() 使 operationId 失效,abort ChatStreamHandle
 * - 迟到 delta / complete / error 被 operationId 校验拒绝
 */

import { Character } from '../../../models/Character';
import { ChatMessage, createChatMessage } from '../../../models/ChatMessage';
import { ChatRole } from '../../../models/ChatRole';
import { ChatRequestOptions } from '../../../models/ChatRequest';
import { ProviderConfig } from '../../../models/ProviderConfig';
import {
  ChatStreamCallbacks,
  ChatStreamHandle,
  ChatDelta,
  ChatStreamResult
} from '../../../models/ChatStreamTypes';
import { NetworkError, NetworkErrorType } from '../../../models/NetworkError';
import { ModelService } from '../../ModelService';
import { CharacterService } from '../../CharacterService';
import { Logger } from '../../../utils/Logger';
import { generateUuid } from '../../../utils/Uuid';
import {
  GroupChatDraftCandidate,
  GeneratedGroupChatDraft,
  GroupChatDraftError,
  GroupChatDraftErrorType,
  MIN_CANDIDATE_COUNT,
  MAX_CANDIDATE_COUNT,
  MIN_DRAFT_MEMBER_COUNT,
  MAX_DRAFT_MEMBER_COUNT,
  MAX_OPENING_MESSAGE_LENGTH,
  MAX_DRAFT_TITLE_LENGTH,
  SUMMARY_FIELD_MAX_LENGTH
} from './GroupChatDraftTypes';

const LOG_TAG: string = 'GroupDraftBuilder';

/** 流式生成 token 上限(草案不需要过长输出) */
const DRAFT_MAX_TOKENS: number = 1200;
/** 流式采样温度(略高,鼓励多样化组合) */
const DRAFT_TEMPERATURE: number = 0.8;

/**
 * AI 建群草案生成服务。
 *
 * 每个 ViewModel 持有独立实例(非单例),保证页面级生命周期隔离。
 * 同一时间只允许一个 generateDraft 进行(由 isGenerating 标记 + operationId 守卫)。
 */
export class GroupChatDraftBuilderService {
  private readonly modelService: ModelService;
  private readonly characterService: CharacterService;
  /** 当前流式句柄(生成期间非 null) */
  private currentHandle: ChatStreamHandle | null = null;
  /** 当前 operationId(迟到回调守卫) */
  private currentOperationId: number = 0;
  /** 是否正在生成 */
  private generating: boolean = false;

  constructor(modelService: ModelService, characterService: CharacterService) {
    this.modelService = modelService;
    this.characterService = characterService;
  }

  /** 是否正在生成 */
  isGenerating(): boolean {
    return this.generating;
  }

  /**
   * 取消当前生成。
   * 使 operationId 失效,abort ChatStreamHandle。
   * 迟到 delta / complete / error 被拒绝。
   */
  cancel(): void {
    if (!this.generating) {
      return;
    }
    this.currentOperationId = this.currentOperationId + 1;
    if (this.currentHandle !== null) {
      try {
        this.currentHandle.abort();
      } catch (e) {
        Logger.warn(LOG_TAG, 'cancel abort failed');
      }
      this.currentHandle = null;
    }
    this.generating = false;
    Logger.info(LOG_TAG, 'cancelled');
  }

  /**
   * 生成群聊草案。
   *
   * 流程:
   * 1. 校验候选数量(2~12)
   * 2. 拍摄模型配置快照(getCurrentConfig)
   * 3. 构建安全摘要 + Builder Prompt
   * 4. 流式生成 + 累计响应
   * 5. 解析 JSON + 本地验证
   * 6. 失败时一次受控修复
   * 7. 验证候选角色仍存在
   *
   * @param description 用户输入的群聊主题/场景描述
   * @param candidates 候选角色列表(已由调用方校验存在性)
   * @returns 生成的草案
   * @throws GroupChatDraftError
   */
  async generateDraft(
    description: string,
    candidates: GroupChatDraftCandidate[]
  ): Promise<GeneratedGroupChatDraft> {
    // 并发守卫
    if (this.generating) {
      throw new GroupChatDraftError(GroupChatDraftErrorType.Unknown, '已有生成进行中');
    }
    // 候选数量校验
    if (candidates.length < MIN_CANDIDATE_COUNT) {
      throw new GroupChatDraftError(
        GroupChatDraftErrorType.CandidatesInsufficient,
        '至少选择 ' + String(MIN_CANDIDATE_COUNT) + ' 个候选角色'
      );
    }
    if (candidates.length > MAX_CANDIDATE_COUNT) {
      throw new GroupChatDraftError(
        GroupChatDraftErrorType.CandidatesExcessive,
        '最多选择 ' + String(MAX_CANDIDATE_COUNT) + ' 个候选角色'
      );
    }

    // 拍摄模型配置快照
    let config: ProviderConfig;
    try {
      config = await this.resolveConfigSnapshot();
    } catch (e) {
      if (e instanceof GroupChatDraftError) {
        throw e;
      }
      throw new GroupChatDraftError(
        GroupChatDraftErrorType.NoModelConfig, '获取模型配置失败'
      );
    }

    this.generating = true;
    this.currentOperationId = this.currentOperationId + 1;
    const opId: number = this.currentOperationId;
    Logger.info(LOG_TAG, 'generateDraft start candidates=' + String(candidates.length)
      + ' opId=' + String(opId));

    try {
      // 第一次生成
      const firstPrompt: ChatMessage[] = this.buildBuilderPrompt(description, candidates);
      const firstRaw: string = await this.streamOnce(firstPrompt, config, opId);
      if (opId !== this.currentOperationId) {
        // 已被取消
        throw new GroupChatDraftError(GroupChatDraftErrorType.Cancelled, '已取消');
      }

      // 尝试解析第一次结果
      let parsed: ParsedDraft;
      try {
        parsed = this.parseAndValidate(firstRaw, candidates);
      } catch (parseError) {
        // 第一次解析失败,进行一次受控修复
        Logger.info(LOG_TAG, 'first parse failed, attempting repair');
        if (opId !== this.currentOperationId) {
          throw new GroupChatDraftError(GroupChatDraftErrorType.Cancelled, '已取消');
        }
        const repairPrompt: ChatMessage[] = this.buildRepairPrompt(
          firstRaw, parseError as GroupChatDraftError
        );
        const repairRaw: string = await this.streamOnce(repairPrompt, config, opId);
        if (opId !== this.currentOperationId) {
          throw new GroupChatDraftError(GroupChatDraftErrorType.Cancelled, '已取消');
        }
        // 修复后解析(不再修复)
        parsed = this.parseAndValidate(repairRaw, candidates);
      }

      // 验证候选角色在生成期间未被删除
      await this.ensureCandidatesStillExist(parsed.orderedCharacterIds, candidates);

      Logger.info(LOG_TAG, 'generateDraft success members=' + String(parsed.orderedCharacterIds.length));
      return {
        title: parsed.title,
        orderedCharacterIds: parsed.orderedCharacterIds,
        rationale: parsed.rationale,
        openingMessage: parsed.openingMessage
      };
    } finally {
      if (opId === this.currentOperationId) {
        this.generating = false;
        this.currentHandle = null;
      }
    }
  }

  // ===== 模型配置快照 =====

  /**
   * 获取生成开始时的模型配置快照。
   * 快照不含 API Key(ProviderConfig 模型本身不含)。
   */
  private async resolveConfigSnapshot(): Promise<ProviderConfig> {
    let config: ProviderConfig | null;
    try {
      config = await this.modelService.getCurrentConfig();
    } catch (e) {
      throw new GroupChatDraftError(
        GroupChatDraftErrorType.NoModelConfig, '读取模型配置失败'
      );
    }
    if (config === null) {
      throw new GroupChatDraftError(
        GroupChatDraftErrorType.NoModelConfig, '未选择模型配置'
      );
    }
    return config;
  }

  // ===== 流式生成 =====

  /**
   * 执行一次流式生成,累计完整响应。
   * @returns 完整响应文本
   * @throws GroupChatDraftError(取消 / 认证 / 网络 / 未知)
   */
  private streamOnce(
    messages: ChatMessage[],
    config: ProviderConfig,
    opId: number
  ): Promise<string> {
    return new Promise<string>((resolve, reject): void => {
      const accumulated: string[] = [];
      const options: ChatRequestOptions = {
        temperature: DRAFT_TEMPERATURE,
        topP: config.topP,
        maxTokens: DRAFT_MAX_TOKENS,
        stream: true,
        responseFormatJson: true
      };

      const callbacks: ChatStreamCallbacks = {
        onStart: (): void => {
          // 无需处理
        },
        onDelta: (delta: ChatDelta): void => {
          if (opId !== this.currentOperationId) {
            return;
          }
          if (delta.content.length > 0) {
            accumulated.push(delta.content);
          }
        },
        onComplete: (result: ChatStreamResult): void => {
          if (opId !== this.currentOperationId) {
            return;
          }
          resolve(result.content);
        },
        onError: (error: NetworkError): void => {
          if (opId !== this.currentOperationId) {
            return;
          }
          reject(this.classifyNetworkError(error));
        }
      };

      const handle: ChatStreamHandle = this.modelService.streamChatWithConfig(
        config, messages, options, callbacks
      );
      // 记录句柄供 cancel 使用
      if (opId === this.currentOperationId) {
        this.currentHandle = handle;
      } else {
        // 已被取消,立即 abort
        try {
          handle.abort();
        } catch (e) {
          // 忽略
        }
        reject(new GroupChatDraftError(GroupChatDraftErrorType.Cancelled, '已取消'));
      }
    });
  }

  /**
   * 将 NetworkError 分类为 GroupChatDraftError。
   */
  private classifyNetworkError(error: NetworkError): GroupChatDraftError {
    if (error.type === NetworkErrorType.Cancelled) {
      return new GroupChatDraftError(GroupChatDraftErrorType.Cancelled, '已取消');
    }
    if (error.type === NetworkErrorType.Authentication) {
      return new GroupChatDraftError(
        GroupChatDraftErrorType.AuthenticationFailed, '模型认证失败'
      );
    }
    return new GroupChatDraftError(
      GroupChatDraftErrorType.NetworkFailed, '网络请求失败'
    );
  }

  // ===== Prompt 构建 =====

  /**
   * 构建第一次 Builder Prompt(System + User)。
   * User 内容含描述、候选别名与安全摘要、JSON Schema 示例。
   */
  private buildBuilderPrompt(
    description: string,
    candidates: GroupChatDraftCandidate[]
  ): ChatMessage[] {
    const system: string =
      '你正在帮助用户规划一个多人聊天草案。\n' +
      '只能从给定候选角色中选择成员。\n' +
      '最终选择 2 到 8 位角色。\n' +
      '不得创造新的角色。\n' +
      '不得修改候选角色设定。\n' +
      '成员顺序表示默认发言顺序。\n' +
      '标题应简洁,不超过 ' + String(MAX_DRAFT_TITLE_LENGTH) + ' 个字。\n' +
      '开场消息是用户可以发送的公开消息草案,可为空。\n' +
      '只返回指定 JSON,不要添加 Markdown 代码块或额外解释。\n' +
      'JSON 格式:\n' +
      '{"title":"群聊标题","orderedMembers":["C1","C3"],"rationale":"推荐原因","openingMessage":"可选的开场用户消息"}';

    const userParts: string[] = [];
    userParts.push('群聊描述:');
    userParts.push(description.trim().length > 0 ? description.trim() : '(用户未提供描述)');
    userParts.push('');
    userParts.push('候选角色:');
    for (let i = 0; i < candidates.length; i++) {
      const c: GroupChatDraftCandidate = candidates[i];
      userParts.push(c.alias + ' | ' + c.name + ' | ' + c.summary);
    }
    userParts.push('');
    userParts.push('请从以上候选中选择 2 到 8 位角色,给出标题、发言顺序、推荐理由和可选开场消息。');
    userParts.push('orderedMembers 只能使用候选别名(C1/C2/...),不要使用真实角色名或 ID。');

    const now: number = Date.now();
    const sysMsg: ChatMessage = createChatMessage(
      'builder-sys-' + generateUuid(), ChatRole.System, system, now
    );
    const userMsg: ChatMessage = createChatMessage(
      'builder-user-' + generateUuid(), ChatRole.User, userParts.join('\n'), now + 1
    );
    return [sysMsg, userMsg];
  }

  /**
   * 构建修复 Prompt。
   * 只包含原始无效输出、期望 JSON Schema、错误类别。
   * 不再次附带完整角色卡。
   */
  private buildRepairPrompt(
    invalidOutput: string,
    parseError: GroupChatDraftError
  ): ChatMessage[] {
    const system: string =
      '你之前返回的内容无法解析为有效草案。请根据错误提示修正并重新返回 JSON。\n' +
      '只返回指定 JSON,不要添加 Markdown 代码块或额外解释。\n' +
      'JSON 格式:\n' +
      '{"title":"群聊标题","orderedMembers":["C1","C3"],"rationale":"推荐原因","openingMessage":"可选的开场用户消息"}';

    const userParts: string[] = [];
    userParts.push('上一次输出(可能包含多余内容):');
    userParts.push(invalidOutput);
    userParts.push('');
    userParts.push('错误类别: ' + parseError.errorType);
    userParts.push('错误说明: ' + parseError.message);
    userParts.push('');
    userParts.push('请修正并重新返回符合格式的 JSON。orderedMembers 只能使用之前给出的候选别名。');

    const now: number = Date.now();
    const sysMsg: ChatMessage = createChatMessage(
      'builder-repair-sys-' + generateUuid(), ChatRole.System, system, now
    );
    const userMsg: ChatMessage = createChatMessage(
      'builder-repair-user-' + generateUuid(), ChatRole.User, userParts.join('\n'), now + 1
    );
    return [sysMsg, userMsg];
  }

  // ===== JSON 解析与验证 =====

  /**
   * 解析并验证模型返回的 JSON。
   * @throws GroupChatDraftError(JsonInvalid / MemberCountInvalid / OutOfPoolMember)
   */
  private parseAndValidate(
    raw: string,
    candidates: GroupChatDraftCandidate[]
  ): ParsedDraft {
    const cleaned: string = this.stripCodeFences(raw);
    let parsed: Object;
    try {
      parsed = JSON.parse(cleaned);
    } catch (e) {
      throw new GroupChatDraftError(
        GroupChatDraftErrorType.JsonInvalid, 'JSON 解析失败'
      );
    }
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      throw new GroupChatDraftError(
        GroupChatDraftErrorType.JsonInvalid, 'JSON 不是对象'
      );
    }
    const record: Record<string, Object> = parsed as Record<string, Object>;

    // title
    const titleObj: Object | undefined = record['title'];
    if (typeof titleObj !== 'string') {
      throw new GroupChatDraftError(
        GroupChatDraftErrorType.JsonInvalid, 'title 不是字符串'
      );
    }
    const title: string = (titleObj as string).trim();
    if (title.length === 0) {
      throw new GroupChatDraftError(
        GroupChatDraftErrorType.JsonInvalid, 'title 为空'
      );
    }
    const safeTitle: string = title.length > MAX_DRAFT_TITLE_LENGTH
      ? title.substring(0, MAX_DRAFT_TITLE_LENGTH) : title;

    // orderedMembers
    const membersObj: Object | undefined = record['orderedMembers'];
    if (!Array.isArray(membersObj)) {
      throw new GroupChatDraftError(
        GroupChatDraftErrorType.JsonInvalid, 'orderedMembers 不是数组'
      );
    }
    const membersArr: Object[] = membersObj as Object[];
    const aliases: string[] = [];
    for (let i = 0; i < membersArr.length; i++) {
      const m: Object = membersArr[i];
      if (typeof m !== 'string') {
        throw new GroupChatDraftError(
          GroupChatDraftErrorType.JsonInvalid, 'orderedMembers 包含非字符串'
        );
      }
      aliases.push((m as string).trim());
    }

    // 成员数量
    if (aliases.length < MIN_DRAFT_MEMBER_COUNT || aliases.length > MAX_DRAFT_MEMBER_COUNT) {
      throw new GroupChatDraftError(
        GroupChatDraftErrorType.MemberCountInvalid,
        '成员数量 ' + String(aliases.length) + ' 不在 '
        + String(MIN_DRAFT_MEMBER_COUNT) + '-' + String(MAX_DRAFT_MEMBER_COUNT) + ' 范围'
      );
    }

    // 别名归属 + 去重
    const aliasToId: Map<string, string> = this.buildAliasMap(candidates);
    const seen: Set<string> = new Set<string>();
    const orderedCharacterIds: string[] = [];
    for (let i = 0; i < aliases.length; i++) {
      const alias: string = aliases[i];
      if (seen.has(alias)) {
        throw new GroupChatDraftError(
          GroupChatDraftErrorType.JsonInvalid, '别名重复: ' + alias
        );
      }
      seen.add(alias);
      const charId: string | undefined = aliasToId.get(alias);
      if (charId === undefined) {
        throw new GroupChatDraftError(
          GroupChatDraftErrorType.OutOfPoolMember, '别名不在候选池: ' + alias
        );
      }
      orderedCharacterIds.push(charId);
    }

    // rationale
    const rationaleObj: Object | undefined = record['rationale'];
    let rationale: string = '';
    if (typeof rationaleObj === 'string') {
      rationale = (rationaleObj as string).trim();
    }

    // openingMessage(可选)
    const openingObj: Object | undefined = record['openingMessage'];
    let openingMessage: string = '';
    if (typeof openingObj === 'string') {
      openingMessage = (openingObj as string).trim();
    }
    if (openingMessage.length > MAX_OPENING_MESSAGE_LENGTH) {
      openingMessage = openingMessage.substring(0, MAX_OPENING_MESSAGE_LENGTH);
    }

    return {
      title: safeTitle,
      orderedCharacterIds: orderedCharacterIds,
      rationale: rationale,
      openingMessage: openingMessage
    };
  }

  /**
   * 去除 Markdown 代码块围栏(```json ... ``` 或 ``` ... ```)。
   */
  private stripCodeFences(raw: string): string {
    let text: string = raw.trim();
    if (text.startsWith('```')) {
      // 去掉首行围栏
      const firstNewline: number = text.indexOf('\n');
      if (firstNewline > 0) {
        text = text.substring(firstNewline + 1);
      }
      // 去掉尾围栏
      const lastFence: number = text.lastIndexOf('```');
      if (lastFence >= 0) {
        text = text.substring(0, lastFence);
      }
      text = text.trim();
    }
    return text;
  }

  /** 构建 alias→characterId 映射 */
  private buildAliasMap(candidates: GroupChatDraftCandidate[]): Map<string, string> {
    const map: Map<string, string> = new Map<string, string>();
    for (let i = 0; i < candidates.length; i++) {
      map.set(candidates[i].alias, candidates[i].characterId);
    }
    return map;
  }

  // ===== 角色存在性验证 =====

  /**
   * 验证草案中所有角色在生成期间未被删除。
   * @throws GroupChatDraftError(CharacterDeleted)
   */
  private async ensureCandidatesStillExist(
    orderedCharacterIds: string[],
    candidates: GroupChatDraftCandidate[]
  ): Promise<void> {
    for (let i = 0; i < orderedCharacterIds.length; i++) {
      const id: string = orderedCharacterIds[i];
      const character: Character | null = await this.characterService.getById(id);
      if (character === null) {
        throw new GroupChatDraftError(
          GroupChatDraftErrorType.CharacterDeleted, '部分候选角色已被删除'
        );
      }
    }
  }

  // ===== 安全摘要构建 =====

  /**
   * 从 Character 列表构建候选摘要(脱敏)。
   * 只取 name + 截断的 description/personality/scenario。
   * 不含 ID / systemPrompt / mesExample / 头像路径 / 创建时间。
   *
   * @param characters 用户选择的候选角色(调用方已去重)
   * @returns 候选摘要列表(alias 按数组顺序生成 C1/C2/...)
   */
  static buildCandidates(characters: Character[]): GroupChatDraftCandidate[] {
    const result: GroupChatDraftCandidate[] = [];
    for (let i = 0; i < characters.length; i++) {
      const c: Character = characters[i];
      const alias: string = 'C' + String(i + 1);
      const summary: string = GroupChatDraftBuilderService.buildSafeSummary(c);
      result.push({
        alias: alias,
        characterId: c.id,
        name: c.name,
        summary: summary
      });
    }
    return result;
  }

  /**
   * 构建单个角色的安全摘要(截断组合)。
   */
  private static buildSafeSummary(c: Character): string {
    const parts: string[] = [];
    if (c.description.trim().length > 0) {
      parts.push('描述: ' + GroupChatDraftBuilderService.truncate(c.description, SUMMARY_FIELD_MAX_LENGTH));
    }
    if (c.personality.trim().length > 0) {
      parts.push('性格: ' + GroupChatDraftBuilderService.truncate(c.personality, SUMMARY_FIELD_MAX_LENGTH));
    }
    if (c.scenario.trim().length > 0) {
      parts.push('场景: ' + GroupChatDraftBuilderService.truncate(c.scenario, SUMMARY_FIELD_MAX_LENGTH));
    }
    if (parts.length === 0) {
      return '(无可用描述)';
    }
    return parts.join(' / ');
  }

  /** 截断字符串到指定长度 */
  private static truncate(text: string, maxLen: number): string {
    const trimmed: string = text.trim();
    if (trimmed.length <= maxLen) {
      return trimmed;
    }
    return trimmed.substring(0, maxLen) + '…';
  }
}

/** 内部解析结果 */
interface ParsedDraft {
  readonly title: string;
  readonly orderedCharacterIds: string[];
  readonly rationale: string;
  readonly openingMessage: string;
}
