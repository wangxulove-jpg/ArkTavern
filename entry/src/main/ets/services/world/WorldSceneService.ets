/**
 * WorldSceneService 世界场景业务服务
 *
 * W-SCENE-1B 引入。当前世界场景和场景消息的唯一正式业务写入口。
 *
 * 职责:
 * - 场景生命周期:startScene / endScene(事务内 + SceneStarted/SceneEnded 事件)
 * - 同一地点最多一个 Active 场景(业务锁,不依赖数据库唯一约束)
 * - 手动写入 User / Character / Narrator 消息(本阶段不调用模型)
 * - 消息 sequenceNumber 事务内分配(依赖 UNIQUE(scene_id, sequence_number) 作为最终防线)
 * - participantCharacterInstanceIds 自动生成(不让 Page 手动填写)
 * - 实例 World / Location / Active 校验
 *
 * 不负责(留待后续阶段):
 * - 模型调用 / 流式 / 停止 / 重试 / 续写
 * - WorldRuntimeService / WorldRuntimeRegistry / WorldPromptAssembler
 * - 角色发言顺序 / 严格顺序 AI 轮次
 * - Prompt 可见性过滤 / 世界记忆 / 关系 / 地点知识 / AI 候选地点 / AI 世界 Builder
 * - 不修改 moveCharacter / forceMoveCharacter / removeCharacterFromWorld / setCharacterInstanceActive
 * - 不自动结束场景(即使角色移动后)
 *
 * 事务规则:
 * - 所有跨表操作使用 DbHelper.runInTransaction
 * - 事务内只调用 Repository 的 *WithStore 方法
 * - 状态写入与事件插入在同一事务;任一失败整体回滚
 *
 * 依赖方向:
 * - WorldSceneService → 6 个世界 Repository + DbHelper
 * - 不依赖 Page / ViewModel / CharacterService / ModelService / Provider
 *
 * 日志安全:
 * - 不记录完整 World/Location/Scene/Message/Instance ID
 * - 不记录消息正文 / recipient / witness / participant 数组内容 / SQL
 * - 仅记录操作类型、senderType、visibility、sequenceNumber、数量、安全错误种类、截断短 ID(前 8 字符)
 */

import { relationalStore } from '@kit.ArkData';
import { DbHelper } from '../../database/DbHelper';
import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { WorldSceneRepository } from '../../repositories/world/WorldSceneRepository';
import { WorldSceneMessageRepository } from '../../repositories/world/WorldSceneMessageRepository';
import { WorldEventRepository } from '../../repositories/world/WorldEventRepository';
import {
  World,
  WorldStatus
} from '../../models/world/World';
import {
  WorldLocation,
  WorldLocationStatus
} from '../../models/world/WorldLocation';
import { WorldCharacterInstance } from '../../models/world/WorldCharacterInstance';
import {
  WorldScene,
  WorldSceneStatus,
  createWorldSceneRecord,
  WORLD_SCENE_ID_PREFIX
} from '../../models/world/WorldScene';
import {
  WorldSceneMessage,
  WorldSceneMessageSenderType,
  WorldSceneMessageVisibility,
  WorldSceneMessageStatus,
  createWorldSceneMessageRecord,
  normalizeIdArray,
  WORLD_SCENE_MESSAGE_ID_PREFIX
} from '../../models/world/WorldSceneMessage';
import {
  WorldEvent,
  WorldEventType,
  createWorldEventRecord,
  WORLD_EVENT_ID_PREFIX
} from '../../models/world/WorldEvent';
import { WorldSceneError } from '../../models/world/WorldSceneError';
import { generateUuid } from '../../utils/Uuid';
import { nowMillis } from '../../utils/Time';
import { Logger } from '../../utils/Logger';

const LOG_TAG: string = 'WorldSceneService';

const SCENE_SUMMARY_MAX: number = 500;
const MESSAGE_CONTENT_MAX: number = 8000;
const EVENT_SUMMARY_MAX: number = 500;

/** addUserMessage 输入参数 */
export interface AddUserMessageInput {
  readonly sceneId: string;
  readonly content: string;
  readonly visibility: WorldSceneMessageVisibility;
  readonly recipientCharacterInstanceIds?: string[];
  readonly replyTargetCharacterInstanceIds?: string[];
}

/** addCharacterMessage 输入参数 */
export interface AddCharacterMessageInput {
  readonly sceneId: string;
  readonly senderCharacterInstanceId: string;
  readonly content: string;
  readonly visibility: WorldSceneMessageVisibility;
  readonly recipientCharacterInstanceIds?: string[];
}

/** addNarratorMessage 输入参数 */
export interface AddNarratorMessageInput {
  readonly sceneId: string;
  readonly content: string;
  readonly witnessCharacterInstanceIds?: string[];
}

export class WorldSceneService {
  private readonly worldRepo: WorldRepository;
  private readonly locationRepo: WorldLocationRepository;
  private readonly instanceRepo: WorldCharacterInstanceRepository;
  private readonly sceneRepo: WorldSceneRepository;
  private readonly messageRepo: WorldSceneMessageRepository;
  private readonly eventRepo: WorldEventRepository;
  private readonly dbHelper: DbHelper;

  constructor(
    worldRepo: WorldRepository,
    locationRepo: WorldLocationRepository,
    instanceRepo: WorldCharacterInstanceRepository,
    sceneRepo: WorldSceneRepository,
    messageRepo: WorldSceneMessageRepository,
    eventRepo: WorldEventRepository,
    dbHelper: DbHelper
  ) {
    this.worldRepo = worldRepo;
    this.locationRepo = locationRepo;
    this.instanceRepo = instanceRepo;
    this.sceneRepo = sceneRepo;
    this.messageRepo = messageRepo;
    this.eventRepo = eventRepo;
    this.dbHelper = dbHelper;
  }

  // ===== 场景生命周期 =====

  /**
   * 开始场景。
   * 事务内:World Active → Location 存在且属于该 World 且 Active → 同 World+Location 无 Active Scene →
   * 创建 Active Scene → 插入 SceneStarted 事件。
   * 不要求地点必须有角色,不自动创建欢迎消息 / 旁白 / 角色消息。
   * 同一地点已有 Active Scene 时拒绝,不自动结束旧场景。
   */
  async startScene(worldId: string, locationId: string): Promise<WorldScene> {
    if (worldId === '') {
      throw WorldSceneError.worldNotFound();
    }
    if (locationId === '') {
      throw WorldSceneError.locationNotFound();
    }

    let result: WorldScene | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        // 校验 World Active
        const world: World | null = await this.worldRepo.getByIdWithStore(store, worldId);
        if (world === null) {
          throw WorldSceneError.worldNotFound();
        }
        if (world.status !== WorldStatus.Active) {
          throw WorldSceneError.worldArchived();
        }

        // 校验 Location 存在且属于该 World 且 Active
        const location: WorldLocation | null =
          await this.locationRepo.getByIdWithStore(store, locationId);
        if (location === null) {
          throw WorldSceneError.locationNotFound();
        }
        if (location.worldId !== worldId) {
          throw WorldSceneError.locationNotInWorld();
        }
        if (location.status !== WorldLocationStatus.Active) {
          throw WorldSceneError.locationArchived();
        }

        // 业务锁:同 World+Location 最多一个 Active Scene
        const existingActive: WorldScene | null =
          await this.sceneRepo.findActiveByWorldAndLocationWithStore(store, worldId, locationId);
        if (existingActive !== null) {
          throw WorldSceneError.sceneAlreadyActive();
        }

        // 创建 Active Scene
        const now: number = nowMillis();
        const scene: WorldScene = createWorldSceneRecord({
          id: WORLD_SCENE_ID_PREFIX + generateUuid(),
          worldId: worldId,
          locationId: locationId,
          status: WorldSceneStatus.Active,
          startedAt: now,
          createdAt: now,
          updatedAt: now
        });
        await this.sceneRepo.insertWithStore(store, scene);

        // 插入 SceneStarted 事件
        await this.eventRepo.insertWithStore(store, buildSceneEvent({
          worldId: worldId,
          eventType: WorldEventType.SceneStarted,
          sourceSceneId: scene.id,
          sourceLocationId: locationId,
          summary: '场景已开始'
        }));

        result = scene;
      },
      'world_scene_start'
    );
    if (result === null) {
      throw WorldSceneError.internal('事务未产生结果');
    }
    const startedScene: WorldScene = result;
    Logger.info(LOG_TAG, `startScene ok shortSceneId=${shortId(startedScene.id)}`);
    return startedScene;
  }

  /**
   * 结束场景。
   * 事务内:Scene 存在 → Scene Active → status=Ended + endedAt=now + updatedAt=now → SceneEnded 事件。
   * 已经 Ended 的场景再次结束抛 SceneAlreadyEnded,不重复创建事件。
   * 不删除消息,不生成自动 Summary。
   */
  async endScene(sceneId: string): Promise<WorldScene> {
    if (sceneId === '') {
      throw WorldSceneError.sceneNotFound();
    }

    let result: WorldScene | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const existing: WorldScene | null = await this.sceneRepo.getByIdWithStore(store, sceneId);
        if (existing === null) {
          throw WorldSceneError.sceneNotFound();
        }
        if (existing.status === WorldSceneStatus.Ended) {
          throw WorldSceneError.sceneAlreadyEnded();
        }

        const now: number = nowMillis();
        const updated: WorldScene = createWorldSceneRecord({
          id: existing.id,
          worldId: existing.worldId,
          locationId: existing.locationId,
          status: WorldSceneStatus.Ended,
          startedAt: existing.startedAt,
          endedAt: now,
          createdAt: existing.createdAt,
          updatedAt: now
        });
        await this.sceneRepo.updateWithStore(store, updated);

        await this.eventRepo.insertWithStore(store, buildSceneEvent({
          worldId: existing.worldId,
          eventType: WorldEventType.SceneEnded,
          sourceSceneId: existing.id,
          sourceLocationId: existing.locationId,
          summary: '场景已结束'
        }));

        result = updated;
      },
      'world_scene_end'
    );
    if (result === null) {
      throw WorldSceneError.internal('事务未产生结果');
    }
    const endedScene: WorldScene = result;
    Logger.info(LOG_TAG, `endScene ok shortSceneId=${shortId(endedScene.id)}`);
    return endedScene;
  }

  // ===== 手动消息写入 =====

  /**
   * 手动写入 User 消息。
   * 仅允许 Public / Private visibility,不允许 Narrator。
   * - Public: recipientIds 必须为空;replyTargetIds 可为空或非空(必须是当前地点 Active 实例)
   * - Private: recipientIds 必须非空;replyTargetIds 必须为空
   * participantCharacterInstanceIds 自动生成:
   *   - Public → 当前地点全部 Active 实例
   *   - Private → recipientIds
   */
  async addUserMessage(input: AddUserMessageInput): Promise<WorldSceneMessage> {
    if (input.visibility === WorldSceneMessageVisibility.Narrator) {
      throw WorldSceneError.invalidVisibility('用户消息不能使用旁白可见范围');
    }
    const recipients: string[] | undefined = normalizeIdArray(input.recipientCharacterInstanceIds);
    const replyTargets: string[] | undefined = normalizeIdArray(input.replyTargetCharacterInstanceIds);

    // 私下消息:replyTargets 必须为空
    if (input.visibility === WorldSceneMessageVisibility.Private) {
      if (recipients === undefined || recipients.length === 0) {
        throw WorldSceneError.recipientRequired();
      }
      if (replyTargets !== undefined && replyTargets.length > 0) {
        throw WorldSceneError.replyTargetNotAllowed();
      }
    } else {
      // Public:recipientIds 必须为空
      if (recipients !== undefined && recipients.length > 0) {
        throw WorldSceneError.recipientNotAllowed();
      }
    }

    const trimmedContent: string = input.content.trim();
    if (trimmedContent === '') {
      throw WorldSceneError.messageContentEmpty();
    }
    const finalContent: string = truncate(trimmedContent, MESSAGE_CONTENT_MAX);

    return await this.insertMessageInTx(input.sceneId, async (store, scene, world, location): Promise<WorldSceneMessage> => {
      // 校验 replyTargets(仅 Public 使用)
      if (input.visibility === WorldSceneMessageVisibility.Public
        && replyTargets !== undefined && replyTargets.length > 0) {
        await this.assertInstancesAtLocationInTx(store, scene.worldId, scene.locationId, replyTargets);
      }
      // 校验 recipients(仅 Private 使用)
      if (input.visibility === WorldSceneMessageVisibility.Private && recipients !== undefined) {
        await this.assertInstancesAtLocationInTx(store, scene.worldId, scene.locationId, recipients);
      }

      // participant 自动生成
      const localActiveInstances: WorldCharacterInstance[] =
        await this.listActiveInstancesAtLocationInTx(store, scene.worldId, scene.locationId);
      const localActiveIds: string[] = [];
      for (let i = 0; i < localActiveInstances.length; i++) {
        localActiveIds.push(localActiveInstances[i].id);
      }
      let participantIds: string[] | undefined;
      if (input.visibility === WorldSceneMessageVisibility.Public) {
        participantIds = normalizeIdArray(localActiveIds);
      } else {
        // Private → recipientIds
        participantIds = recipients;
      }

      const sequenceNumber: number = await this.allocateSequenceNumberInTx(store, scene.id);
      const now: number = nowMillis();
      const message: WorldSceneMessage = createWorldSceneMessageRecord({
        id: WORLD_SCENE_MESSAGE_ID_PREFIX + generateUuid(),
        worldId: scene.worldId,
        sceneId: scene.id,
        senderType: WorldSceneMessageSenderType.User,
        senderCharacterInstanceId: undefined,
        content: finalContent,
        sequenceNumber: sequenceNumber,
        status: WorldSceneMessageStatus.Completed,
        generationBatchId: undefined,
        visibility: input.visibility,
        recipientCharacterInstanceIds: recipients,
        participantCharacterInstanceIds: participantIds,
        witnessCharacterInstanceIds: undefined,
        replyTargetCharacterInstanceIds: replyTargets,
        createdAt: now,
        updatedAt: now
      });
      await this.messageRepo.insertWithStore(store, message);
      return message;
    });
  }

  /**
   * 手动写入 Character 消息(用户手动录入的角色台词,不调用模型)。
   * 仅允许 Public / Private visibility。
   * - Public: recipientIds 必须为空
   * - Private: recipientIds 必须非空;recipient 中不得包含 sender 自己;全部 recipient 位于同一场景地点且 Active
   * sender 实例必须存在 + 属于当前 World + 位于 Scene.locationId + Active。
   * participant 自动生成:
   *   - Public → 当前地点全部 Active 实例
   *   - Private → senderInstanceId + recipientIds
   */
  async addCharacterMessage(input: AddCharacterMessageInput): Promise<WorldSceneMessage> {
    if (input.visibility === WorldSceneMessageVisibility.Narrator) {
      throw WorldSceneError.invalidVisibility('角色消息不能使用旁白可见范围');
    }
    if (input.senderCharacterInstanceId === '') {
      throw WorldSceneError.characterInstanceNotFound();
    }
    const recipients: string[] | undefined = normalizeIdArray(input.recipientCharacterInstanceIds);

    if (input.visibility === WorldSceneMessageVisibility.Private) {
      if (recipients === undefined || recipients.length === 0) {
        throw WorldSceneError.recipientRequired();
      }
      // recipient 不得包含 sender 自己
      for (let i = 0; i < recipients.length; i++) {
        if (recipients[i] === input.senderCharacterInstanceId) {
          throw WorldSceneError.invalidOperation('私下消息接收者不能包含发言角色自身');
        }
      }
    } else {
      // Public
      if (recipients !== undefined && recipients.length > 0) {
        throw WorldSceneError.recipientNotAllowed();
      }
    }

    const trimmedContent: string = input.content.trim();
    if (trimmedContent === '') {
      throw WorldSceneError.messageContentEmpty();
    }
    const finalContent: string = truncate(trimmedContent, MESSAGE_CONTENT_MAX);

    return await this.insertMessageInTx(input.sceneId, async (store, scene, world, location): Promise<WorldSceneMessage> => {
      // 校验 sender 实例
      const senderInstance: WorldCharacterInstance | null =
        await this.instanceRepo.getByIdWithStore(store, input.senderCharacterInstanceId);
      if (senderInstance === null) {
        throw WorldSceneError.characterInstanceNotFound();
      }
      if (senderInstance.worldId !== scene.worldId) {
        throw WorldSceneError.characterInstanceNotInWorld();
      }
      if (senderInstance.currentLocationId !== scene.locationId) {
        throw WorldSceneError.characterInstanceNotAtSceneLocation();
      }
      if (!senderInstance.isActive) {
        throw WorldSceneError.characterInstanceInactive();
      }

      // 校验 recipients(仅 Private)
      if (input.visibility === WorldSceneMessageVisibility.Private && recipients !== undefined) {
        await this.assertInstancesAtLocationInTx(store, scene.worldId, scene.locationId, recipients);
      }

      // participant 自动生成
      const localActiveInstances: WorldCharacterInstance[] =
        await this.listActiveInstancesAtLocationInTx(store, scene.worldId, scene.locationId);
      const localActiveIds: string[] = [];
      for (let i = 0; i < localActiveInstances.length; i++) {
        localActiveIds.push(localActiveInstances[i].id);
      }
      let participantIds: string[] | undefined;
      if (input.visibility === WorldSceneMessageVisibility.Public) {
        participantIds = normalizeIdArray(localActiveIds);
      } else {
        // Private → senderInstanceId + recipientIds
        const combined: string[] = [input.senderCharacterInstanceId];
        if (recipients !== undefined) {
          for (let i = 0; i < recipients.length; i++) {
            combined.push(recipients[i]);
          }
        }
        participantIds = normalizeIdArray(combined);
      }

      const sequenceNumber: number = await this.allocateSequenceNumberInTx(store, scene.id);
      const now: number = nowMillis();
      const message: WorldSceneMessage = createWorldSceneMessageRecord({
        id: WORLD_SCENE_MESSAGE_ID_PREFIX + generateUuid(),
        worldId: scene.worldId,
        sceneId: scene.id,
        senderType: WorldSceneMessageSenderType.Character,
        senderCharacterInstanceId: input.senderCharacterInstanceId,
        content: finalContent,
        sequenceNumber: sequenceNumber,
        status: WorldSceneMessageStatus.Completed,
        generationBatchId: undefined,
        visibility: input.visibility,
        recipientCharacterInstanceIds: recipients,
        participantCharacterInstanceIds: participantIds,
        witnessCharacterInstanceIds: undefined,
        replyTargetCharacterInstanceIds: undefined,
        createdAt: now,
        updatedAt: now
      });
      await this.messageRepo.insertWithStore(store, message);
      return message;
    });
  }

  /**
   * 手动写入 Narrator 消息(旁白或动作)。
   * 固定 senderType=Narrator, visibility=Narrator, recipientIds=undefined, replyTargets=undefined。
   * witnessIds 可为空;非空时必须属于当前 World + 位于当前 Scene 地点 + Active。
   * 空 witness 表示只有用户主持者知道。
   * participant = witnessIds。
   */
  async addNarratorMessage(input: AddNarratorMessageInput): Promise<WorldSceneMessage> {
    const witnessIds: string[] | undefined = normalizeIdArray(input.witnessCharacterInstanceIds);

    const trimmedContent: string = input.content.trim();
    if (trimmedContent === '') {
      throw WorldSceneError.messageContentEmpty();
    }
    const finalContent: string = truncate(trimmedContent, MESSAGE_CONTENT_MAX);

    return await this.insertMessageInTx(input.sceneId, async (store, scene, world, location): Promise<WorldSceneMessage> => {
      // 校验 witnessIds(若非空)
      if (witnessIds !== undefined && witnessIds.length > 0) {
        await this.assertInstancesAtLocationInTx(store, scene.worldId, scene.locationId, witnessIds);
      }

      const sequenceNumber: number = await this.allocateSequenceNumberInTx(store, scene.id);
      const now: number = nowMillis();
      const message: WorldSceneMessage = createWorldSceneMessageRecord({
        id: WORLD_SCENE_MESSAGE_ID_PREFIX + generateUuid(),
        worldId: scene.worldId,
        sceneId: scene.id,
        senderType: WorldSceneMessageSenderType.Narrator,
        senderCharacterInstanceId: undefined,
        content: finalContent,
        sequenceNumber: sequenceNumber,
        status: WorldSceneMessageStatus.Completed,
        generationBatchId: undefined,
        visibility: WorldSceneMessageVisibility.Narrator,
        recipientCharacterInstanceIds: undefined,
        participantCharacterInstanceIds: witnessIds,
        witnessCharacterInstanceIds: witnessIds,
        replyTargetCharacterInstanceIds: undefined,
        createdAt: now,
        updatedAt: now
      });
      await this.messageRepo.insertWithStore(store, message);
      return message;
    });
  }

  // ===== 事务内辅助方法 =====

  /**
   * 在事务内执行消息写入通用流程:
   * 校验 Scene 存在且 Active → 校验 World Active → 校验 Location Active →
   * 调用 buildMessage 回调构造并写入消息。
   * 返回写入的消息。
   */
  private async insertMessageInTx(
    sceneId: string,
    buildMessage: (
      store: relationalStore.RdbStore,
      scene: WorldScene,
      world: World,
      location: WorldLocation
    ) => Promise<WorldSceneMessage>
  ): Promise<WorldSceneMessage> {
    if (sceneId === '') {
      throw WorldSceneError.sceneNotFound();
    }
    let result: WorldSceneMessage | null = null;
    await this.dbHelper.runInTransaction(
      async (store: relationalStore.RdbStore): Promise<void> => {
        const scene: WorldScene | null = await this.sceneRepo.getByIdWithStore(store, sceneId);
        if (scene === null) {
          throw WorldSceneError.sceneNotFound();
        }
        if (scene.status !== WorldSceneStatus.Active) {
          throw WorldSceneError.sceneNotActive();
        }
        const world: World | null = await this.worldRepo.getByIdWithStore(store, scene.worldId);
        if (world === null) {
          throw WorldSceneError.worldNotFound();
        }
        if (world.status !== WorldStatus.Active) {
          throw WorldSceneError.worldArchived();
        }
        const location: WorldLocation | null =
          await this.locationRepo.getByIdWithStore(store, scene.locationId);
        if (location === null) {
          throw WorldSceneError.locationNotFound();
        }
        if (location.status !== WorldLocationStatus.Active) {
          throw WorldSceneError.locationArchived();
        }
        const message: WorldSceneMessage = await buildMessage(store, scene, world, location);
        result = message;
      },
      'world_scene_message_add'
    );
    if (result === null) {
      throw WorldSceneError.internal('事务未产生结果');
    }
    const savedMessage: WorldSceneMessage = result;
    Logger.info(LOG_TAG,
      `addMessage ok senderType=${savedMessage.senderType} visibility=${savedMessage.visibility} seq=${savedMessage.sequenceNumber}`);
    return savedMessage;
  }

  /**
   * 在事务内分配下一条消息的 sequenceNumber。
   * - 无消息 → 0
   * - 否则 → max + 1
   * 依赖 UNIQUE(scene_id, sequence_number) 作为最终防线。
   */
  private async allocateSequenceNumberInTx(
    store: relationalStore.RdbStore,
    sceneId: string
  ): Promise<number> {
    const maxSeq: number = await this.messageRepo.getMaxSequenceNumberWithStore(store, sceneId);
    return maxSeq + 1;
  }

  /**
   * 在事务内列出指定 World+Location 下的全部 Active 角色实例。
   */
  private async listActiveInstancesAtLocationInTx(
    store: relationalStore.RdbStore,
    worldId: string,
    locationId: string
  ): Promise<WorldCharacterInstance[]> {
    const all: WorldCharacterInstance[] =
      await this.instanceRepo.listByLocationWithStore(store, worldId, locationId);
    const active: WorldCharacterInstance[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].isActive) {
        active.push(all[i]);
      }
    }
    return active;
  }

  /**
   * 在事务内校验全部 instanceIds 都属于指定 World+Location 且 Active。
   * - 任一不存在 → CharacterInstanceNotFound
   * - 任一不属于 World → CharacterInstanceNotInWorld
   * - 任一不在 locationId → CharacterInstanceNotAtSceneLocation
   * - 任一 Inactive → CharacterInstanceInactive
   */
  private async assertInstancesAtLocationInTx(
    store: relationalStore.RdbStore,
    worldId: string,
    locationId: string,
    instanceIds: string[]
  ): Promise<void> {
    for (let i = 0; i < instanceIds.length; i++) {
      const id: string = instanceIds[i];
      const instance: WorldCharacterInstance | null =
        await this.instanceRepo.getByIdWithStore(store, id);
      if (instance === null) {
        throw WorldSceneError.characterInstanceNotFound();
      }
      if (instance.worldId !== worldId) {
        throw WorldSceneError.characterInstanceNotInWorld();
      }
      if (instance.currentLocationId !== locationId) {
        throw WorldSceneError.characterInstanceNotAtSceneLocation();
      }
      if (!instance.isActive) {
        throw WorldSceneError.characterInstanceInactive();
      }
    }
  }
}

// ===== 内部工具函数 =====

/** 截断到最大长度。 */
function truncate(value: string, max: number): string {
  if (value.length <= max) {
    return value;
  }
  return value.substring(0, max);
}

/** 截断短 ID(前 8 字符)用于日志。 */
function shortId(id: string): string {
  if (id.length <= 8) {
    return id;
  }
  return id.substring(0, 8);
}

/** buildSceneEvent 参数 */
interface BuildSceneEventOptions {
  readonly worldId: string;
  readonly eventType: WorldEventType;
  readonly sourceSceneId: string;
  readonly sourceLocationId: string;
  readonly summary: string;
}

/** 构造场景相关 WorldEvent 记录(自动生成 id 与时间戳)。 */
function buildSceneEvent(options: BuildSceneEventOptions): WorldEvent {
  return createWorldEventRecord({
    id: WORLD_EVENT_ID_PREFIX + generateUuid(),
    worldId: options.worldId,
    eventType: options.eventType,
    sourceSceneId: options.sourceSceneId,
    sourceLocationId: options.sourceLocationId,
    summary: truncate(options.summary, EVENT_SUMMARY_MAX),
    occurredAt: nowMillis(),
    createdAt: nowMillis()
  });
}
