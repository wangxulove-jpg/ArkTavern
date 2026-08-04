/**
 * WorldHomeViewModel 世界列表页 ViewModel(W-UI-1)
 *
 * 职责:
 * - 加载真实世界列表(WorldRepository.listAll)
 * - 为每个 World 汇总地点数量和角色实例数量(有上限,避免 N+1 无限制并发)
 * - 映射 UI 模型 WorldSummaryUiModel
 * - 处理加载错误
 * - 处理页面销毁后的迟到结果(loadOperationId + disposed)
 *
 * 依赖方向:
 * Page → ViewModel → Repository(只读)
 *
 * 不调用 WorldStateService 的写方法。
 * 不在 ArkUI Builder 中查询数据库。
 */

import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationRepository } from '../../repositories/world/WorldLocationRepository';
import { WorldCharacterInstanceRepository } from '../../repositories/world/WorldCharacterInstanceRepository';
import { Logger } from '../../utils/Logger';
import {
  WorldSummaryUiModel,
  WorldListState
} from './WorldUiModels';
import { WorldStatus } from '../../models/world/World';
import { DatabaseError } from '../../models/DatabaseError';

const LOG_TAG: string = 'WorldHomeViewModel';

/** 单次列表加载最多汇总 World 数量(防止异常数据爆炸) */
const MAX_WORLDS_FOR_SUMMARY: number = 100;

export class WorldHomeViewModel {
  /** 世界仓储(只读) */
  private readonly worldRepository: WorldRepository;
  /** 地点仓储(只读,用于 countByWorld) */
  private readonly locationRepository: WorldLocationRepository;
  /** 角色实例仓储(只读,用于 listByWorld 计数) */
  private readonly characterInstanceRepository: WorldCharacterInstanceRepository;

  /** 当前加载状态 */
  state: WorldListState = WorldListState.Loading;
  /** 用户可见的安全错误消息(空字符串表示无错误) */
  errorMessage: string = '';
  /** 世界列表 UI 模型 */
  worlds: WorldSummaryUiModel[] = [];

  /** 当前页面加载操作 ID(每次 reload 自增,拒绝旧请求覆盖新请求) */
  private loadOperationId: number = 0;
  /** 页面是否已销毁 */
  private disposed: boolean = false;

  constructor(
    worldRepository: WorldRepository,
    locationRepository: WorldLocationRepository,
    characterInstanceRepository: WorldCharacterInstanceRepository
  ) {
    this.worldRepository = worldRepository;
    this.locationRepository = locationRepository;
    this.characterInstanceRepository = characterInstanceRepository;
  }

  /**
   * 重新加载世界列表。
   * - 幂等:可重复调用
   * - 使用 loadOperationId 拒绝旧请求覆盖新请求
   * - 销毁后不再更新状态
   */
  async reload(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.loadOperationId = this.loadOperationId + 1;
    const operationId: number = this.loadOperationId;

    this.state = WorldListState.Loading;
    this.errorMessage = '';

    try {
      const worlds = await this.worldRepository.listAll();
      // 旧请求结果到达时直接丢弃
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }

      // 截断超大数据集
      const truncated: boolean = worlds.length > MAX_WORLDS_FOR_SUMMARY;
      const limited = truncated ? worlds.slice(0, MAX_WORLDS_FOR_SUMMARY) : worlds;

      // 顺序汇总每个 World 的地点数量和角色实例数量
      // Repository 基于 RDBStore,顺序查询避免连接争用
      const summaryList: WorldSummaryUiModel[] = new Array<WorldSummaryUiModel>(limited.length);
      for (let i: number = 0; i < limited.length; i++) {
        if (operationId !== this.loadOperationId || this.disposed) {
          return;
        }
        const w = limited[i];
        let locationCount: number = 0;
        let characterCount: number = 0;
        try {
          locationCount = await this.locationRepository.countByWorld(w.id);
        } catch (e) {
          Logger.warn(LOG_TAG, 'countByWorld failed: ' + this.safeErrorCategory(e)
            + ', worldShortId=' + this.shortId(w.id));
          locationCount = 0;
        }
        if (operationId !== this.loadOperationId || this.disposed) {
          return;
        }
        try {
          const instances = await this.characterInstanceRepository.listByWorld(w.id);
          characterCount = instances.length;
        } catch (e) {
          Logger.warn(LOG_TAG, 'listByWorld(characters) failed: ' + this.safeErrorCategory(e)
            + ', worldShortId=' + this.shortId(w.id));
          characterCount = 0;
        }
        if (operationId !== this.loadOperationId || this.disposed) {
          return;
        }
        summaryList[i] = {
          id: w.id,
          name: w.name,
          description: w.description,
          status: w.status as WorldStatus,
          locationCount: locationCount,
          characterCount: characterCount,
          updatedAt: w.updatedAt
        };
      }

      // 二次校验:旧请求结果到达时直接丢弃
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      this.worlds = summaryList;
      if (summaryList.length === 0) {
        this.state = WorldListState.Empty;
      } else {
        this.state = WorldListState.Ready;
      }
      if (truncated) {
        Logger.warn(LOG_TAG, 'worlds truncated to ' + String(MAX_WORLDS_FOR_SUMMARY));
      }
    } catch (e) {
      if (operationId !== this.loadOperationId || this.disposed) {
        return;
      }
      Logger.error(LOG_TAG, 'reload failed: ' + this.safeErrorCategory(e));
      this.worlds = [];
      this.errorMessage = '世界数据加载失败,请重试';
      this.state = WorldListState.Error;
    }
  }

  /**
   * 标记页面已销毁,后续 reload / 迟到结果均不再更新状态。
   */
  dispose(): void {
    this.disposed = true;
  }

  /**
   * 安全的错误分类(不输出 SQL / 完整错误信息)。
   */
  private safeErrorCategory(e: Object): string {
    if (e instanceof DatabaseError) {
      return 'DatabaseError:' + e.type;
    }
    const msg: string = (e as Error).message ?? 'unknown';
    // 仅取前 60 字符,且不输出可能包含 SQL 的细节
    if (msg.length > 60) {
      return 'Error:' + msg.substring(0, 60);
    }
    return 'Error:' + msg;
  }

  /**
   * 截断短 ID(取最后 8 字符)用于日志定位。
   */
  private shortId(id: string): string {
    if (id.length <= 8) {
      return id;
    }
    return id.substring(id.length - 8);
  }
}
