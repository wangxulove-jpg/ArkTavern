/**
 * WorldMapBackgroundService 世界地图背景图业务服务(W2A3-WORLD-MAP-BACKGROUND)
 *
 * 职责:
 * - 从系统相册导入图片到应用沙箱,并计算 fitScale(图片像素 → 世界坐标)
 * - 保存/加载世界背景图元数据
 * - 旋转背景图:同步转换所有地点放置坐标,保证地点相对图片位置不变
 * - 移除背景图:删除记录与沙箱文件
 *
 * 坐标模型:
 * - 图片中心世界坐标 = (imageWidth * fitScale / 2, imageHeight * fitScale / 2)
 * - 旋转围绕图片中心;每次旋转对所有 placement 的绝对坐标做增量旋转
 * - 无背景图的世界使用绝对世界坐标(原有行为不变)
 *
 * 依赖方向:
 * Service → Repository(只读+写入) / DbHelper / fileIo / ImageKit
 * 不依赖页面 / ViewModel / Provider / 网络。
 */

import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { DbHelper } from '../../database/DbHelper';
import { WorldRepository } from '../../repositories/world/WorldRepository';
import { WorldLocationMapPlacementRepository } from '../../repositories/world/WorldLocationMapPlacementRepository';
import { WorldMapBackgroundRepository } from '../../repositories/world/WorldMapBackgroundRepository';
import {
  WorldMapBackground,
  createWorldMapBackgroundRecord,
  WORLD_MAP_BACKGROUND_ID_PREFIX,
  backgroundWorldWidth,
  backgroundWorldHeight,
  backgroundCenterX,
  backgroundCenterY,
  rotatePointAroundCenter
} from '../../models/world/WorldMapBackground';
import { WorldLocationMapPlacement } from '../../models/world/WorldLocationMapPlacement';
import { DatabaseError } from '../../models/DatabaseError';
import { Logger } from '../../utils/Logger';
import { MapBackgroundPort } from '../../viewmodels/world/WorldImmersiveMapViewModel';

const LOG_TAG: string = 'WorldMapBackgroundService';

/** 目标世界画布宽度(背景图 fit 到的世界尺寸) */
const MAP_WORLD_WIDTH: number = 1200;
/** 目标世界画布高度 */
const MAP_WORLD_HEIGHT: number = 800;
/** 图片区域内边距(导入时地点映射保留的边距) */
const MAP_EDGE_PADDING: number = 40;
/** 背景图存储目录 */
const BG_DIR: string = 'world_map_backgrounds';

export interface ImportBackgroundResult {
  readonly success: boolean;
  readonly background: WorldMapBackground | null;
  readonly placements: WorldLocationMapPlacement[];
  readonly errorMessage: string;
}

export interface RotateBackgroundResult {
  readonly success: boolean;
  readonly background: WorldMapBackground | null;
  readonly placements: WorldLocationMapPlacement[];
  readonly errorMessage: string;
}

export interface RemoveBackgroundResult {
  readonly success: boolean;
  readonly errorMessage: string;
}

export function computeBackgroundFitScale(imageWidth: number, imageHeight: number): number {
  if (imageWidth <= 0 || imageHeight <= 0) {
    return 1;
  }
  return Math.min(MAP_WORLD_WIDTH / imageWidth, MAP_WORLD_HEIGHT / imageHeight);
}

export class WorldMapBackgroundService implements MapBackgroundPort {
  private readonly context: common.Context;
  private readonly worldRepo: WorldRepository;
  private readonly placementRepo: WorldLocationMapPlacementRepository;
  private readonly backgroundRepo: WorldMapBackgroundRepository;
  private readonly dbHelper: DbHelper;
  private readonly bgDirPath: string;

  constructor(
    context: common.Context,
    worldRepo: WorldRepository,
    placementRepo: WorldLocationMapPlacementRepository,
    backgroundRepo: WorldMapBackgroundRepository,
    dbHelper: DbHelper
  ) {
    this.context = context;
    this.worldRepo = worldRepo;
    this.placementRepo = placementRepo;
    this.backgroundRepo = backgroundRepo;
    this.dbHelper = dbHelper;
    this.bgDirPath = context.filesDir + '/' + BG_DIR;
  }

  async loadBackground(worldId: string): Promise<WorldMapBackground | null> {
    if (worldId === '') {
      return null;
    }
    try {
      return await this.backgroundRepo.getByWorldId(worldId);
    } catch (e) {
      Logger.warn(LOG_TAG, 'loadBackground failed: ' + this.safeErrorCategory(e));
      return null;
    }
  }

  /**
   * 从相册选择 URI 导入背景图。
   * 步骤:
   * 1. 验证世界存在
   * 2. 复制图片到沙箱(覆盖旧文件,旧文件随后清理)
   * 3. 读取图片尺寸,计算 fitScale
   * 4. 将现有地点放置坐标映射到图片区域内(保持相对布局)
   * 5. 事务内 upsert 背景记录 + 更新所有放置坐标
   */
  async importBackground(worldId: string, sourceUri: string): Promise<ImportBackgroundResult> {
    try {
      const world = await this.worldRepo.getById(worldId);
      if (world === null) {
        return { success: false, background: null, placements: [], errorMessage: '世界不存在' };
      }
      if (sourceUri === '') {
        return { success: false, background: null, placements: [], errorMessage: '图片来源无效' };
      }
      await this.ensureDir();

      const existing: WorldMapBackground | null = await this.backgroundRepo.getByWorldId(worldId);
      const targetUri: string = await this.copyImageToSandbox(worldId, sourceUri, existing);

      const dimensions: number[] = await this.readImageDimensions(targetUri);
      const imageWidth: number = dimensions[0];
      const imageHeight: number = dimensions[1];
      if (imageWidth <= 0 || imageHeight <= 0) {
        return { success: false, background: null, placements: [], errorMessage: '无法读取图片尺寸' };
      }
      const fitScale: number = computeBackgroundFitScale(imageWidth, imageHeight);

      const now: number = Date.now();
      const background: WorldMapBackground = createWorldMapBackgroundRecord({
        id: WORLD_MAP_BACKGROUND_ID_PREFIX + now.toString() + '-' + worldId.substring(worldId.length - 8),
        worldId: worldId,
        imageUri: targetUri,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        rotation: 0,
        fitScale: fitScale,
        createdAt: existing !== null ? existing.createdAt : now,
        updatedAt: now
      });

      const placements: WorldLocationMapPlacement[] =
        await this.placementRepo.listByWorldId(worldId);
      const remapped: WorldLocationMapPlacement[] =
        this.remapPlacementsIntoImage(placements, background);

      await this.dbHelper.runInTransaction(async (store): Promise<void> => {
        await this.backgroundRepo.upsertWithStore(store, background);
        for (let i: number = 0; i < remapped.length; i++) {
          await this.placementRepo.upsertWithStore(store, remapped[i]);
        }
      }, 'world_map_background_upsert');

      if (existing !== null && existing.imageUri !== targetUri) {
        this.deleteFileQuietly(existing.imageUri);
      }
      Logger.info(LOG_TAG, 'importBackground: ok, worldShortId=' + worldId.substring(worldId.length - 8)
        + ', img=' + imageWidth.toString() + 'x' + imageHeight.toString()
        + ', fitScale=' + fitScale.toFixed(3)
        + ', placements=' + remapped.length.toString());
      return { success: true, background: background, placements: remapped, errorMessage: '' };
    } catch (e) {
      const msg: string = this.safeErrorCategory(e);
      Logger.error(LOG_TAG, 'importBackground failed: ' + msg);
      return { success: false, background: null, placements: [], errorMessage: '导入失败,请重试' };
    }
  }

  /**
   * 旋转背景图 deltaRadians 弧度。
   * 所有地点放置坐标围绕图片中心做同样的增量旋转,保证地点相对图片不错位。
   */
  async rotateBackground(worldId: string, deltaRadians: number): Promise<RotateBackgroundResult> {
    try {
      const background: WorldMapBackground | null = await this.backgroundRepo.getByWorldId(worldId);
      if (background === null) {
        return { success: false, background: null, placements: [], errorMessage: '未设置背景图' };
      }
      const newRotation: number = background.rotation + deltaRadians;
      const updated: WorldMapBackground = {
        id: background.id,
        worldId: background.worldId,
        imageUri: background.imageUri,
        imageWidth: background.imageWidth,
        imageHeight: background.imageHeight,
        rotation: newRotation,
        fitScale: background.fitScale,
        createdAt: background.createdAt,
        updatedAt: Date.now()
      };
      const cx: number = backgroundCenterX(background);
      const cy: number = backgroundCenterY(background);
      const placements: WorldLocationMapPlacement[] =
        await this.placementRepo.listByWorldId(worldId);
      const rotated: WorldLocationMapPlacement[] = new Array<WorldLocationMapPlacement>(placements.length);
      for (let i: number = 0; i < placements.length; i++) {
        const p: WorldLocationMapPlacement = placements[i];
        const newPos: number[] = rotatePointAroundCenter(p.positionX, p.positionY, cx, cy, deltaRadians);
        rotated[i] = {
          id: p.id,
          worldId: p.worldId,
          locationId: p.locationId,
          positionX: newPos[0],
          positionY: newPos[1],
          positionZ: p.positionZ,
          rotationX: p.rotationX,
          rotationY: p.rotationY,
          rotationZ: p.rotationZ,
          scale: p.scale,
          createdAt: p.createdAt,
          updatedAt: Date.now()
        };
      }

      await this.dbHelper.runInTransaction(async (store): Promise<void> => {
        await this.backgroundRepo.upsertWithStore(store, updated);
        for (let i: number = 0; i < rotated.length; i++) {
          await this.placementRepo.upsertWithStore(store, rotated[i]);
        }
      }, 'world_map_background_upsert');

      Logger.info(LOG_TAG, 'rotateBackground: ok, worldShortId=' + worldId.substring(worldId.length - 8)
        + ', deltaDeg=' + (deltaRadians * 180 / Math.PI).toFixed(1)
        + ', placements=' + rotated.length.toString());
      return { success: true, background: updated, placements: rotated, errorMessage: '' };
    } catch (e) {
      Logger.error(LOG_TAG, 'rotateBackground failed: ' + this.safeErrorCategory(e));
      return { success: false, background: null, placements: [], errorMessage: '旋转失败,请重试' };
    }
  }

  /** 移除背景图:删除数据库记录 + 沙箱文件。地点坐标保持现状。 */
  async removeBackground(worldId: string): Promise<RemoveBackgroundResult> {
    try {
      const background: WorldMapBackground | null = await this.backgroundRepo.getByWorldId(worldId);
      if (background === null) {
        return { success: true, errorMessage: '' };
      }
      await this.dbHelper.runInTransaction(async (store): Promise<void> => {
        await this.backgroundRepo.deleteByWorldIdWithStore(store, worldId);
      }, 'world_map_background_delete');
      this.deleteFileQuietly(background.imageUri);
      Logger.info(LOG_TAG, 'removeBackground: ok, worldShortId=' + worldId.substring(worldId.length - 8));
      return { success: true, errorMessage: '' };
    } catch (e) {
      Logger.error(LOG_TAG, 'removeBackground failed: ' + this.safeErrorCategory(e));
      return { success: false, errorMessage: '移除失败,请重试' };
    }
  }

  private async ensureDir(): Promise<void> {
    try {
      const exists: boolean = fs.accessSync(this.bgDirPath);
      if (exists) {
        return;
      }
    } catch (_e) {
      // 目录不存在,继续创建
    }
    await fs.mkdir(this.bgDirPath, true);
  }

  private async copyImageToSandbox(
    worldId: string,
    sourceUri: string,
    existing: WorldMapBackground | null
  ): Promise<string> {
    const ext: string = this.extractExtension(sourceUri);
    const fileName: string = 'world_' + worldId.substring(worldId.length - 8) + '_' + Date.now().toString() + ext;
    const targetPath: string = this.bgDirPath + '/' + fileName;
    const targetUri: string = 'file://' + targetPath;

    const sourceFile: fs.File = await fs.open(sourceUri, fs.OpenMode.READ_ONLY);
    try {
      const targetFile: fs.File = await fs.open(targetPath,
        fs.OpenMode.WRITE_ONLY | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      try {
        const BUFFER_SIZE: number = 4 * 1024 * 1024;
        const tempBuf: ArrayBuffer = new ArrayBuffer(BUFFER_SIZE);
        let offset: number = 0;
        while (true) {
          const readLen: number = await fs.read(sourceFile.fd, tempBuf, { offset: offset });
          if (readLen <= 0) {
            break;
          }
          const writeData: ArrayBuffer = readLen < BUFFER_SIZE
            ? tempBuf.slice(0, readLen) : tempBuf;
          await fs.write(targetFile.fd, writeData);
          offset += readLen;
        }
      } finally {
        await fs.close(targetFile);
      }
    } finally {
      await fs.close(sourceFile);
    }
    return targetUri;
  }

  private async readImageDimensions(imageUri: string): Promise<number[]> {
    const file: fs.File = await fs.open(imageUri, fs.OpenMode.READ_ONLY);
    let imageSource: image.ImageSource | null = null;
    try {
      imageSource = image.createImageSource(file.fd);
      if (imageSource === null) {
        return [0, 0];
      }
      const info: image.ImageInfo = await imageSource.getImageInfo();
      return [info.size.width, info.size.height];
    } finally {
      if (imageSource !== null) {
        try {
          imageSource.release();
        } catch (_e) {
          // 忽略释放异常
        }
      }
      await fs.close(file);
    }
  }

  /**
   * 将现有放置坐标按相对布局映射到图片区域内。
   * - 无放置或仅一个点时,放置到图片中心区域
   * - 多个点时,原包围盒等比缩放到图片区域(四周留 MAP_EDGE_PADDING 边距)
   */
  private remapPlacementsIntoImage(
    placements: WorldLocationMapPlacement[],
    background: WorldMapBackground
  ): WorldLocationMapPlacement[] {
    const result: WorldLocationMapPlacement[] = new Array<WorldLocationMapPlacement>(placements.length);
    if (placements.length === 0) {
      return result;
    }
    const imgWorldW: number = backgroundWorldWidth(background);
    const imgWorldH: number = backgroundWorldHeight(background);
    const targetMinX: number = MAP_EDGE_PADDING;
    const targetMaxX: number = imgWorldW - MAP_EDGE_PADDING;
    const targetMinY: number = MAP_EDGE_PADDING;
    const targetMaxY: number = imgWorldH - MAP_EDGE_PADDING;

    let minX: number = placements[0].positionX;
    let maxX: number = placements[0].positionX;
    let minY: number = placements[0].positionY;
    let maxY: number = placements[0].positionY;
    for (let i: number = 1; i < placements.length; i++) {
      minX = Math.min(minX, placements[i].positionX);
      maxX = Math.max(maxX, placements[i].positionX);
      minY = Math.min(minY, placements[i].positionY);
      maxY = Math.max(maxY, placements[i].positionY);
    }
    const spanX: number = maxX - minX;
    const spanY: number = maxY - minY;
    const singlePoint: boolean = spanX < 1 && spanY < 1;
    const targetCenterX: number = (targetMinX + targetMaxX) / 2;
    const targetCenterY: number = (targetMinY + targetMaxY) / 2;

    for (let i: number = 0; i < placements.length; i++) {
      const p: WorldLocationMapPlacement = placements[i];
      let nx: number;
      let ny: number;
      if (singlePoint) {
        nx = targetCenterX;
        ny = targetCenterY;
      } else {
        nx = spanX < 1
          ? targetCenterX
          : targetMinX + ((p.positionX - minX) / spanX) * (targetMaxX - targetMinX);
        ny = spanY < 1
          ? targetCenterY
          : targetMinY + ((p.positionY - minY) / spanY) * (targetMaxY - targetMinY);
      }
      result[i] = {
        id: p.id,
        worldId: p.worldId,
        locationId: p.locationId,
        positionX: nx,
        positionY: ny,
        positionZ: p.positionZ,
        rotationX: p.rotationX,
        rotationY: p.rotationY,
        rotationZ: p.rotationZ,
        scale: p.scale,
        createdAt: p.createdAt,
        updatedAt: Date.now()
      };
    }
    return result;
  }

  private extractExtension(sourceUri: string): string {
    const lower: string = sourceUri.toLowerCase();
    const dotIndex: number = lower.lastIndexOf('.');
    if (dotIndex >= 0) {
      const ext: string = lower.substring(dotIndex);
      if (ext.length >= 2 && ext.length <= 5 && /^\.[a-z0-9]+$/.test(ext)) {
        return ext;
      }
    }
    return '.img';
  }

  private deleteFileQuietly(uri: string): void {
    try {
      if (uri.startsWith('file://')) {
        const path: string = uri.substring('file://'.length);
        if (fs.accessSync(path)) {
          fs.unlinkSync(path);
        }
      }
    } catch (e) {
      Logger.warn(LOG_TAG, 'deleteFileQuietly ignored: ' + this.safeErrorCategory(e));
    }
  }

  private safeErrorCategory(e: Object): string {
    if (e instanceof DatabaseError) {
      return 'DatabaseError:' + e.type;
    }
    const msg: string = (e as Error).message ?? 'unknown';
    if (msg.length > 60) {
      return 'Error:' + msg.substring(0, 60);
    }
    return 'Error:' + msg;
  }
}
