/**
 * HumanoidMappingViewModel 手动人形骨骼映射视图模型
 *
 * T-3D.6E P3: 手动骨骼映射页面业务逻辑层。
 *
 * 职责:
 * - 加载当前模型配置和 GltfModelInfo(获取 nodeNames)
 * - 加载已存在的 ManualHumanoidMapping(若有)
 * - 加载自动映射结果(BoneMappingResult)
 * - 提供标准关节列表、骨骼树、当前选中关节
 * - 提供绑定/解绑/清空/自动匹配/验证/保存能力
 * - 不直接依赖 ArkUI/ArkGraphics3D
 * - 通过 HumanoidMappingStore 持久化
 * - 通过 Character3DService 读取模型信息
 *
 * 不读取聊天 / Prompt / API Key。
 */

import { Character3DService, Character3DModelConfig, VrmReparseResult } from '../services/Character3DService';
import { AvatarLibraryService } from '../services/AvatarLibraryService';
import { AvatarRecord } from '../storage/AvatarLibraryStore';
import { HumanoidMappingStore, HumanoidMappingLoadResult } from '../storage/HumanoidMappingStore';
import { Logger } from '../utils/Logger';
import {
  HumanoidBone,
  REQUIRED_BONES,
  ALL_STANDARD_BONES,
  BoneMappingResult,
  HumanoidBoneMapping,
  SkeletonProfile
} from '../models/character3d/HumanoidBone';
import {
  ManualHumanoidMapping,
  HumanoidJointBinding,
  BoneMappingMethod,
  createEmptyManualMapping,
  createDefaultAlignmentConfig,
  setJointBinding,
  removeJointBinding,
  clearAllBindings,
  refreshMappingStats,
  serializeManualMapping,
  deserializeManualMapping,
  computeSkeletonHash,
  SkeletonHashInput,
  isSkeletonHashMatched,
  ModelAlignmentConfig
} from '../models/character3d/ManualHumanoidMapping';
import {
  HumanoidMappingValidationResult,
  HumanoidMappingValidatorInput,
  validateHumanoidMapping,
  createEmptyValidationResult,
  HumanoidMappingIssue
} from '../models/character3d/HumanoidMappingValidator';
import { GltfModelInfo } from '../parser/GltfValidator';
import { SurfaceBonePickingService } from '../services/SurfaceBonePickingService';
import {
  BoneClickCandidate,
  SurfacePickingInput,
  MappingInteractionMode
} from '../models/character3d/SurfaceBoneCandidate';
import {
  Character3DDisplayConfig,
  createDefaultDisplayConfig
} from '../models/character3d/Character3DDisplayConfig';
import { mapBones } from '../models/character3d/HumanoidBoneMapper';
import { VrmVersion } from '../models/character3d/vrm/VrmVersion';

const LOG_TAG: string = 'HumanoidMappingVM';

/** 可选骨骼(ALL_STANDARD_BONES 中除 REQUIRED_BONES 外的) */
const OPTIONAL_BONES: HumanoidBone[] = computeOptionalBones();

/**
 * 骨骼树节点(用于 UI 显示)。
 */
export interface BoneTreeNode {
  /** 节点索引 */
  nodeIndex: number;
  /** 节点名(可能为空) */
  name: string;
  /** 父节点索引(-1 为根) */
  parentIndex: number;
  /** 子节点索引列表 */
  children: number[];
  /** 是否为 skin joint */
  isSkinJoint: boolean;
  /** 是否已被映射 */
  isMapped: boolean;
  /** 映射到的标准关节名(若已映射) */
  mappedTargetName: string;
  /** 缩进层级(根=0) */
  level: number;
}

/**
 * 标准关节列表项(用于 UI 显示)。
 */
export interface StandardJointItem {
  /** 标准关节 */
  bone: HumanoidBone;
  /** 中文名 */
  displayName: string;
  /** 是否必需 */
  required: boolean;
  /** 当前绑定(可能为 null) */
  binding: HumanoidJointBinding | null;
  /** 状态文案 */
  statusText: string;
  /** 状态颜色 */
  statusColor: string;
}

/**
 * T-4.2B: 骨骼映射诊断信息(0 结果时显示)。
 */
export interface MappingDiagnosticInfo {
  /** Avatar ID 前 8 位 */
  avatarId: string;
  /** Avatar 显示名 */
  displayName: string;
  /** 模型文件名 */
  modelFileName: string;
  /** 是否 VRM */
  isVrm: boolean;
  /** VRM 版本文本 */
  vrmVersionText: string;
  /** VRM 扩展是否存在 */
  vrmExtensionPresent: boolean;
  /** VRM 声明骨骼数 */
  declaredHumanBoneCount: number;
  /** VRM 有效骨骼数 */
  validHumanBoneCount: number;
  /** 转换后 binding 数量 */
  bindingCount: number;
  /** HumanoidProvider 来源 */
  providerSource: string;
  /** 是否命中旧缓存 */
  legacyCacheHit: boolean;
  /** 重解析错误信息 */
  reparseError: string;
}

export class HumanoidMappingViewModel {
  private readonly character3DService: Character3DService;
  private readonly mappingStore: HumanoidMappingStore;
  private readonly avatarLibraryService: AvatarLibraryService;

  /** T-4.2B: 当前 Avatar ID(缓存隔离主键) */
  private avatarId: string = '';
  /** T-4.2B: 当前 Avatar 记录 */
  private avatarRecord: AvatarRecord | null = null;
  /** T-4.2B: 是否 VRM */
  private isVrm: boolean = false;
  /** T-4.2B: VRM 版本 */
  private vrmVersion: VrmVersion = VrmVersion.NonVrm;
  /** T-4.2B: 模型文件 SHA-256 */
  private sourceSha256: string = '';
  /** T-4.2B: VRM 重解析结果(诊断用) */
  private vrmReparseResult: VrmReparseResult | null = null;
  /** T-4.2B: HumanoidProvider 来源 */
  private providerSource: string = 'None';
  /** T-4.2B: VRM 声明骨骼数 */
  private declaredHumanBoneCount: number = 0;
  /** T-4.2B: VRM 有效骨骼数 */
  private validHumanBoneCount: number = 0;
  /** T-4.2B: 是否命中旧缓存(诊断用) */
  private legacyCacheHit: boolean = false;

  /** 当前模型配置 */
  private modelConfig: Character3DModelConfig = {
    modelUri: '', displayName: '', fileExists: false
  };
  /** 当前模型信息 */
  private modelInfo: GltfModelInfo | null = null;
  /** 当前手动映射 */
  private mapping: ManualHumanoidMapping | null = null;
  /** 自动映射结果 */
  private autoMappingResult: BoneMappingResult | null = null;
  /** 验证结果 */
  private validationResult: HumanoidMappingValidationResult = createEmptyValidationResult();
  /** 父节点索引数组 */
  private parentIndices: number[] = [];
  /** 当前 skeleton hash */
  private currentSkeletonHash: string = '';
  /** 当前选中的标准关节 */
  private selectedBone: HumanoidBone | null = null;
  /** 当前选中的源骨骼节点索引 */
  private selectedSourceNodeIndex: number = -1;
  /** 搜索关键字 */
  private searchKeyword: string = '';
  /** T-3D.6F-A: 表面点选服务 */
  private pickingService: SurfaceBonePickingService = new SurfaceBonePickingService();
  /** T-3D.6F-A: 点选交互模式 */
  private interactionMode: MappingInteractionMode = MappingInteractionMode.Normal;
  /** T-3D.6F-A: 当前候选列表 */
  private currentCandidates: BoneClickCandidate[] = [];
  /** T-3D.6F-A: GLB buffer 缓存 */
  private glbBuffer: ArrayBuffer | null = null;
  /** T-3D.6F-A: 当前模型显示配置(用于计算世界变换和相机参数) */
  private displayConfig: Character3DDisplayConfig = createDefaultDisplayConfig();
  /** T-3D.6F-A: 当前用户确认的候选索引(-1 未确认) */
  private confirmedCandidateIndex: number = -1;

  constructor(
    character3DService: Character3DService,
    mappingStore: HumanoidMappingStore,
    avatarLibraryService: AvatarLibraryService
  ) {
    this.character3DService = character3DService;
    this.mappingStore = mappingStore;
    this.avatarLibraryService = avatarLibraryService;
  }

  /**
   * T-4.2B: 初始化:按 avatarId 加载 Avatar、模型信息、已有映射。
   *
   * 流程:
   * 1. 优先使用传入的 avatarId;为空时读取 AvatarLibraryService.getActiveAvatarId()
   * 2. 通过 AvatarLibraryService.getAvatar(avatarId) 获取 AvatarRecord
   * 3. 使用 record.modelUri / displayName / sourceSha256
   * 4. 加载 GltfModelInfo,计算 skeletonHash
   * 5. 按 avatarId 加载手动映射;无则尝试旧 modelId 缓存迁移
   * 6. VRM 模型:调用 reparseVrmForUri 获取 VrmExplicit boneMapping
   *    非 VRM 模型:调用 mapBones(nodeNames) 获取名称匹配 boneMapping
   * 7. VRM 旧缓存 mappingCount=0 或 source=Auto 时忽略旧缓存
   *
   * @param avatarId 可选,路由参数传入的 avatarId;为空时读取 active avatar
   * @returns true 初始化成功,false 无 Avatar 或失败
   */
  async initialize(avatarId?: string): Promise<boolean> {
    try {
      // 1. 解析 avatarId
      let resolvedAvatarId: string = avatarId ?? '';
      if (resolvedAvatarId.length === 0) {
        resolvedAvatarId = await this.avatarLibraryService.getActiveAvatarId();
      }
      if (resolvedAvatarId.length === 0) {
        Logger.warn(LOG_TAG, 'initialize: no active avatar');
        return false;
      }
      this.avatarId = resolvedAvatarId;

      // 2. 获取 AvatarRecord
      const record: AvatarRecord | null = await this.avatarLibraryService.getAvatar(resolvedAvatarId);
      if (record === null) {
        Logger.warn(LOG_TAG, 'initialize: avatar not found, id=' + resolvedAvatarId.substring(0, 8));
        return false;
      }
      this.avatarRecord = record;
      this.isVrm = record.isVrm;
      this.sourceSha256 = record.sourceSha256;
      this.declaredHumanBoneCount = record.declaredHumanBoneCount;
      this.validHumanBoneCount = record.validHumanBoneCount;

      // VRM 版本字符串转枚举
      this.vrmVersion = this.parseVrmVersion(record.vrmVersion, record.isVrm);

      // 3. 填充 modelConfig(供旧代码使用)
      this.modelConfig = {
        modelUri: record.modelUri,
        displayName: record.displayName,
        fileExists: true
      };

      // 4. 加载模型信息
      this.modelInfo = await this.character3DService.getModelInfoByUri(record.modelUri);
      if (this.modelInfo === null) {
        Logger.warn(LOG_TAG, 'initialize: getModelInfoByUri returned null');
        return false;
      }

      // 5. 计算 skeleton hash
      this.currentSkeletonHash = this.computeCurrentSkeletonHash(this.modelInfo);

      // 6. 按 avatarId 加载手动映射
      const loadResult: HumanoidMappingLoadResult = await this.mappingStore.load(
        resolvedAvatarId, record.sourceSha256
      );
      if (loadResult.mapping !== null
        && isSkeletonHashMatched(loadResult.mapping, this.currentSkeletonHash)) {
        // T-4.2B: VRM 旧缓存检测 - mappingCount=0 或全部 Auto 时忽略
        if (record.isVrm && this.isLegacyVrmCache(loadResult.mapping)) {
          Logger.info(LOG_TAG, 'initialize: ignoring legacy VRM cache (0 or Auto mappings)');
          await this.mappingStore.delete(resolvedAvatarId);
          this.mapping = createEmptyManualMapping(
            record.displayName, record.sourceSha256, this.currentSkeletonHash, resolvedAvatarId
          );
        } else {
          this.mapping = loadResult.mapping;
          // 确保 avatarId 字段已回填(旧迁移数据可能为空)
          if (this.mapping.avatarId.length === 0) {
            this.mapping.avatarId = resolvedAvatarId;
          }
          Logger.info(LOG_TAG, 'initialize: loaded existing mapping, joints='
            + this.mapping.joints.length);
        }
      } else {
        // T-4.2B: 尝试旧 modelId 缓存迁移
        const legacyResult: HumanoidMappingLoadResult = await this.mappingStore.loadLegacyByModelId(
          record.displayName, record.sourceSha256
        );
        if (legacyResult.mapping !== null
          && isSkeletonHashMatched(legacyResult.mapping, this.currentSkeletonHash)) {
          this.legacyCacheHit = true;
          // VRM 旧缓存检测
          if (record.isVrm && this.isLegacyVrmCache(legacyResult.mapping)) {
            Logger.info(LOG_TAG, 'initialize: ignoring legacy VRM cache by modelId (0 or Auto)');
            await this.mappingStore.deleteLegacyByModelId(record.displayName);
          } else {
            // 迁移到 avatarId key
            legacyResult.mapping.avatarId = resolvedAvatarId;
            this.mapping = legacyResult.mapping;
            await this.mappingStore.save(this.mapping);
            await this.mappingStore.deleteLegacyByModelId(record.displayName);
            Logger.info(LOG_TAG, 'initialize: migrated legacy mapping to avatarId, joints='
              + this.mapping.joints.length);
          }
        }
        if (this.mapping === null) {
          this.mapping = createEmptyManualMapping(
            record.displayName, record.sourceSha256, this.currentSkeletonHash, resolvedAvatarId
          );
          Logger.info(LOG_TAG, 'initialize: created empty mapping');
        }
      }

      // 7. 获取自动映射结果
      if (record.isVrm) {
        // VRM: 重新解析获取 VrmExplicit boneMapping
        const reparse: VrmReparseResult = await this.character3DService.reparseVrmForUri(
          record.modelUri, record.displayName, record.sourceSha256
        );
        this.vrmReparseResult = reparse;
        if (reparse.boneMapping !== null) {
          this.autoMappingResult = reparse.boneMapping;
          this.providerSource = reparse.providerSource;
          this.declaredHumanBoneCount = reparse.declaredHumanBoneCount;
          this.validHumanBoneCount = reparse.validHumanBoneCount;
        } else {
          this.providerSource = 'None';
          Logger.warn(LOG_TAG, 'initialize: VRM reparse failed, error=' + reparse.error);
        }
      } else {
        // 非 VRM: 名称匹配
        this.autoMappingResult = mapBones(
          this.modelInfo.nodeNames, record.displayName, this.modelInfo.hasSkins
        );
        this.providerSource = this.autoMappingResult.mappings.length > 0 ? 'Auto' : 'None';
      }

      // 8. T-3D.6F-A: 预加载 GLB buffer(用于表面点选)
      if (this.modelInfo.hasSkins) {
        this.glbBuffer = await this.character3DService.getGlbBuffer();
        if (this.glbBuffer !== null) {
          Logger.info(LOG_TAG, 'initialize: glbBuffer loaded, size=' + this.glbBuffer.byteLength);
        }
        this.displayConfig = await this.character3DService.getDisplayConfig(record.displayName);
        Logger.info(LOG_TAG, 'initialize: displayConfig scale=' + this.displayConfig.scale
          + ', camDist=' + this.displayConfig.cameraDistance);
      }

      Logger.info(LOG_TAG, 'initialize ok: avatarId=' + resolvedAvatarId.substring(0, 8)
        + ', isVrm=' + this.isVrm
        + ', providerSource=' + this.providerSource
        + ', declaredBones=' + this.declaredHumanBoneCount
        + ', validBones=' + this.validHumanBoneCount);
      return true;
    } catch (e) {
      Logger.error(LOG_TAG, 'initialize failed: ' + (e as Error)?.message);
      return false;
    }
  }

  /**
   * T-4.2B: 解析 VRM 版本字符串为枚举。
   */
  private parseVrmVersion(versionStr: string, isVrm: boolean): VrmVersion {
    if (!isVrm) {
      return VrmVersion.NonVrm;
    }
    if (versionStr === 'Vrm0x') {
      return VrmVersion.Vrm0x;
    }
    if (versionStr === 'Vrm1') {
      return VrmVersion.Vrm1;
    }
    return VrmVersion.NonVrm;
  }

  /**
   * T-4.2B: 检测旧 VRM 缓存是否应被忽略。
   *
   * 条件:映射关节数为 0,或全部为 Auto(非 VrmDeclared)。
   */
  private isLegacyVrmCache(mapping: ManualHumanoidMapping): boolean {
    if (mapping.joints.length === 0) {
      return true;
    }
    for (let i: number = 0; i < mapping.joints.length; i++) {
      if (mapping.joints[i].mappingMethod !== BoneMappingMethod.Auto) {
        return false;
      }
    }
    return true;
  }

  /**
   * 计算当前模型的 skeleton hash(基于 nodeNames)。
   *
   * 简化版:不区分 skin joints,使用全部 nodes。
   */
  private computeCurrentSkeletonHash(modelInfo: GltfModelInfo): string {
    const input: SkeletonHashInput = {
      jointCount: modelInfo.nodeCount,
      jointNames: modelInfo.nodeNames,
      parentIndices: [], // 不持有 parent 信息,留空
      inverseBindMatrixCount: 0
    };
    return computeSkeletonHash(input);
  }

  /**
   * 获取当前映射(只读)。
   */
  getMapping(): ManualHumanoidMapping | null {
    return this.mapping;
  }

  /**
   * 获取当前验证结果。
   */
  getValidationResult(): HumanoidMappingValidationResult {
    return this.validationResult;
  }

  /**
   * 获取模型显示名。
   */
  getModelDisplayName(): string {
    return this.modelConfig.displayName;
  }

  /**
   * T-4.2B: 获取当前 Avatar ID。
   */
  getAvatarId(): string {
    return this.avatarId;
  }

  /**
   * T-4.2B: 是否 VRM 模型。
   */
  getIsVrm(): boolean {
    return this.isVrm;
  }

  /**
   * T-4.2B: 获取 VRM 版本枚举。
   */
  getVrmVersion(): VrmVersion {
    return this.vrmVersion;
  }

  /**
   * T-4.2B: 获取 VRM 版本显示文本。
   */
  getVrmVersionText(): string {
    if (!this.isVrm) {
      return 'GLB';
    }
    if (this.vrmVersion === VrmVersion.Vrm0x) {
      return 'VRM 0.x';
    }
    if (this.vrmVersion === VrmVersion.Vrm1) {
      return 'VRM 1.0';
    }
    return 'VRM(未知版本)';
  }

  /**
   * T-4.2B: 获取模型文件 URI(仅显示文件名部分,不含完整路径)。
   */
  getModelFileName(): string {
    if (this.avatarRecord === null) {
      return '';
    }
    // 从 modelUri 中提取文件名(file://<path>/<name>.vrm)
    const uri: string = this.avatarRecord.modelUri;
    const slashIdx: number = uri.lastIndexOf('/');
    if (slashIdx >= 0 && slashIdx < uri.length - 1) {
      return uri.substring(slashIdx + 1);
    }
    return uri;
  }

  /**
   * T-4.2B: 获取 HumanoidProvider 来源。
   */
  getProviderSource(): string {
    return this.providerSource;
  }

  /**
   * T-4.2B: 获取 VRM 声明骨骼数。
   */
  getDeclaredHumanBoneCount(): number {
    return this.declaredHumanBoneCount;
  }

  /**
   * T-4.2B: 获取 VRM 有效骨骼数。
   */
  getValidHumanBoneCount(): number {
    return this.validHumanBoneCount;
  }

  /**
   * T-4.2B: 是否命中旧缓存(诊断用)。
   */
  isLegacyCacheHit(): boolean {
    return this.legacyCacheHit;
  }

  /**
   * T-4.2B: 获取 VRM 重解析结果(诊断用)。
   */
  getVrmReparseResult(): VrmReparseResult | null {
    return this.vrmReparseResult;
  }

  /**
   * T-4.2B: 构建诊断信息(0 结果时显示)。
   *
   * 包含:当前 Avatar、当前读取文件、VRM 扩展是否存在、
   * humanBones 原始数量、转换后 binding 数量、Provider source、是否命中旧缓存。
   */
  buildDiagnosticInfo(): MappingDiagnosticInfo {
    const info: MappingDiagnosticInfo = {
      avatarId: this.avatarId.substring(0, 8),
      displayName: this.modelConfig.displayName,
      modelFileName: this.getModelFileName(),
      isVrm: this.isVrm,
      vrmVersionText: this.getVrmVersionText(),
      vrmExtensionPresent: this.vrmReparseResult !== null && this.vrmReparseResult.isVrm,
      declaredHumanBoneCount: this.declaredHumanBoneCount,
      validHumanBoneCount: this.validHumanBoneCount,
      bindingCount: this.autoMappingResult !== null ? this.autoMappingResult.mappings.length : 0,
      providerSource: this.providerSource,
      legacyCacheHit: this.legacyCacheHit,
      reparseError: this.vrmReparseResult !== null ? this.vrmReparseResult.error : ''
    };
    return info;
  }

  /**
   * 获取模型 node 总数。
   */
  getTotalNodeCount(): number {
    return this.modelInfo !== null ? this.modelInfo.nodeCount : 0;
  }

  /**
   * 获取 node 名称列表。
   */
  getNodeNames(): string[] {
    return this.modelInfo !== null ? this.modelInfo.nodeNames : [];
  }

  /**
   * 获取 skin 是否存在。
   */
  hasSkins(): boolean {
    return this.modelInfo !== null ? this.modelInfo.hasSkins : false;
  }

  /**
   * 选中标准关节。
   */
  selectBone(bone: HumanoidBone): void {
    this.selectedBone = bone;
  }

  /**
   * 获取当前选中的标准关节。
   */
  getSelectedBone(): HumanoidBone | null {
    return this.selectedBone;
  }

  /**
   * 选中源骨骼节点。
   */
  selectSourceNode(nodeIndex: number): void {
    this.selectedSourceNodeIndex = nodeIndex;
  }

  /**
   * 获取当前选中的源骨骼节点索引。
   */
  getSelectedSourceNodeIndex(): number {
    return this.selectedSourceNodeIndex;
  }

  /**
   * 设置搜索关键字。
   */
  setSearchKeyword(keyword: string): void {
    this.searchKeyword = keyword;
  }

  /**
   * 获取搜索关键字。
   */
  getSearchKeyword(): string {
    return this.searchKeyword;
  }

  /**
   * 构建标准关节列表(用于 UI)。
   */
  buildStandardJointItems(): StandardJointItem[] {
    if (this.mapping === null) {
      return [];
    }
    const items: StandardJointItem[] = [];
    for (let i: number = 0; i < ALL_STANDARD_BONES.length; i++) {
      const bone: HumanoidBone = ALL_STANDARD_BONES[i];
      const binding: HumanoidJointBinding | null = this.findBinding(bone);
      const required: boolean = REQUIRED_BONES.indexOf(bone) >= 0;
      const item: StandardJointItem = {
        bone: bone,
        displayName: getBoneDisplayName(bone),
        required: required,
        binding: binding,
        statusText: this.buildBindingStatusText(bone, binding),
        statusColor: this.buildBindingStatusColor(bone, binding)
      };
      items.push(item);
    }
    return items;
  }

  /**
   * 构建绑定状态文案。
   */
  private buildBindingStatusText(
    bone: HumanoidBone,
    binding: HumanoidJointBinding | null
  ): string {
    if (binding === null) {
      return '未匹配';
    }
    if (binding.mappingMethod === BoneMappingMethod.VrmDeclared) {
      return 'VRM标准';
    }
    if (binding.mappingMethod === BoneMappingMethod.Auto) {
      return '自动(' + (binding.confidence * 100).toFixed(0) + '%)';
    }
    if (binding.mappingMethod === BoneMappingMethod.ManualSurface) {
      return '表面(' + (binding.confidence * 100).toFixed(0) + '%)';
    }
    if (binding.mappingMethod === BoneMappingMethod.Manual
      || binding.mappingMethod === BoneMappingMethod.ManualTree) {
      return '手动';
    }
    Logger.warn(LOG_TAG, 'unknown mappingMethod: ' + binding.mappingMethod);
    return '未知来源';
  }

  /**
   * 构建绑定状态颜色。
   */
  private buildBindingStatusColor(
    bone: HumanoidBone,
    binding: HumanoidJointBinding | null
  ): string {
    if (binding === null) {
      return REQUIRED_BONES.indexOf(bone) >= 0 ? '#d9534f' : '#999999';
    }
    if (binding.mappingMethod === BoneMappingMethod.VrmDeclared) {
      return '#6f42c1';
    }
    if (binding.mappingMethod === BoneMappingMethod.Auto) {
      return binding.confidence >= 0.85 ? '#28a745' : '#ffc107';
    }
    if (binding.mappingMethod === BoneMappingMethod.ManualSurface) {
      return '#17a2b8';
    }
    if (binding.mappingMethod === BoneMappingMethod.Manual
      || binding.mappingMethod === BoneMappingMethod.ManualTree) {
      return '#007DFF';
    }
    return '#999999';
  }

  /**
   * 查找指定标准关节的绑定。
   */
  private findBinding(bone: HumanoidBone): HumanoidJointBinding | null {
    if (this.mapping === null) {
      return null;
    }
    for (let i: number = 0; i < this.mapping.joints.length; i++) {
      if (this.mapping.joints[i].targetJoint === bone) {
        return this.mapping.joints[i];
      }
    }
    return null;
  }

  /**
   * 匹配当前选中的标准关节到当前选中的源骨骼节点。
   *
   * @returns true 匹配成功
   */
  bindSelected(): boolean {
    if (this.mapping === null
      || this.selectedBone === null
      || this.selectedSourceNodeIndex < 0) {
      return false;
    }
    const nodeNames: string[] = this.getNodeNames();
    if (this.selectedSourceNodeIndex >= nodeNames.length) {
      return false;
    }
    const sourceName: string = nodeNames[this.selectedSourceNodeIndex];
    const binding: HumanoidJointBinding = {
      targetJoint: this.selectedBone,
      sourceNodeIndex: this.selectedSourceNodeIndex,
      sourceBoneName: sourceName,
      mappingMethod: BoneMappingMethod.Manual,
      confidence: 1.0
    };
    setJointBinding(this.mapping, binding);
    refreshMappingStats(this.mapping, REQUIRED_BONES, OPTIONAL_BONES);
    return true;
  }

  /**
   * 取消指定标准关节的匹配。
   */
  unbindBone(bone: HumanoidBone): boolean {
    if (this.mapping === null) {
      return false;
    }
    const removed: HumanoidJointBinding | null = removeJointBinding(this.mapping, bone);
    if (removed !== null) {
      refreshMappingStats(this.mapping, REQUIRED_BONES, OPTIONAL_BONES);
      return true;
    }
    return false;
  }

  /**
   * 清空所有匹配。
   */
  clearAll(): boolean {
    if (this.mapping === null) {
      return false;
    }
    clearAllBindings(this.mapping);
    return true;
  }

  /**
   * 自动匹配:将自动映射结果应用到当前手动映射。
   *
   * T-4.1 A10: 区分 VRM 显式映射和普通名称匹配。
   * - VRM 映射(sourceNodeIndex >= 0 且 confidence === 1.0)使用 VrmDeclared,
   *   直接使用 sourceNodeIndex,避免名称查找失败
   * - 普通名称匹配使用 Auto,通过 findNodeIndexByName 查找
   *
   * 策略:仅接受 confidence >= 0.85 的映射。
   */
  applyAutoMapping(): number {
    if (this.mapping === null || this.autoMappingResult === null) {
      return 0;
    }
    let appliedCount: number = 0;
    for (let i: number = 0; i < this.autoMappingResult.mappings.length; i++) {
      const autoMapping: HumanoidBoneMapping = this.autoMappingResult.mappings[i];
      if (autoMapping.confidence < 0.85) {
        continue;
      }
      // T-4.1: VRM 显式映射优先使用 sourceNodeIndex
      let nodeIndex: number = autoMapping.sourceNodeIndex;
      let method: BoneMappingMethod = BoneMappingMethod.Auto;
      if (autoMapping.sourceNodeIndex >= 0) {
        // VRM 显式映射:直接使用 nodeIndex
        method = BoneMappingMethod.VrmDeclared;
      } else {
        // 普通名称匹配:通过名称查找
        nodeIndex = this.findNodeIndexByName(autoMapping.sourceNodeName);
      }
      const binding: HumanoidJointBinding = {
        targetJoint: autoMapping.standardBone,
        sourceNodeIndex: nodeIndex,
        sourceBoneName: autoMapping.sourceNodeName,
        mappingMethod: method,
        confidence: autoMapping.confidence
      };
      if (binding.sourceNodeIndex >= 0) {
        setJointBinding(this.mapping, binding);
        appliedCount++;
      }
    }
    if (appliedCount > 0) {
      refreshMappingStats(this.mapping, REQUIRED_BONES, OPTIONAL_BONES);
    }
    Logger.info(LOG_TAG, 'applyAutoMapping: applied=' + appliedCount);
    return appliedCount;
  }

  /**
   * T-4.1 A10: 读取 VRM 标准骨骼(VRM 模型专用)。
   *
   * T-4.2B: 改用 reparseVrmForUri(modelUri) 而非 reparseVrmForCurrentModel(),
   * 确保按当前 avatarId 对应的模型文件解析,不依赖全局 config。
   *
   * @returns 应用的骨骼数;非 VRM 或失败时返回 0
   */
  async applyVrmDeclaredMapping(): Promise<number> {
    if (this.mapping === null || this.avatarRecord === null) {
      return 0;
    }
    const reparse: VrmReparseResult = await this.character3DService.reparseVrmForUri(
      this.avatarRecord.modelUri,
      this.avatarRecord.displayName,
      this.avatarRecord.sourceSha256
    );
    this.vrmReparseResult = reparse;
    if (!reparse.isVrm || reparse.boneMapping === null) {
      Logger.warn(LOG_TAG, 'applyVrmDeclaredMapping: not VRM or no boneMapping, error=' + reparse.error);
      return 0;
    }
    // 更新 autoMappingResult 为 VRM 重解析结果
    this.autoMappingResult = reparse.boneMapping;
    this.providerSource = reparse.providerSource;
    this.declaredHumanBoneCount = reparse.declaredHumanBoneCount;
    this.validHumanBoneCount = reparse.validHumanBoneCount;
    let appliedCount: number = 0;
    for (let i: number = 0; i < reparse.boneMapping.mappings.length; i++) {
      const m: HumanoidBoneMapping = reparse.boneMapping.mappings[i];
      if (m.sourceNodeIndex < 0) {
        continue;
      }
      const binding: HumanoidJointBinding = {
        targetJoint: m.standardBone,
        sourceNodeIndex: m.sourceNodeIndex,
        sourceBoneName: m.sourceNodeName,
        mappingMethod: BoneMappingMethod.VrmDeclared,
        confidence: 1.0
      };
      setJointBinding(this.mapping, binding);
      appliedCount++;
    }
    if (appliedCount > 0) {
      refreshMappingStats(this.mapping, REQUIRED_BONES, OPTIONAL_BONES);
    }
    Logger.info(LOG_TAG, 'applyVrmDeclaredMapping: applied=' + appliedCount
      + ', declared=' + reparse.declaredHumanBoneCount
      + ', valid=' + reparse.validHumanBoneCount);
    return appliedCount;
  }

  /**
   * T-4.1 A10: 检测当前模型的 autoMappingResult 是否来自 VRM 显式声明。
   *
   * 用于 UI 决定按钮文案("读取 VRM 标准骨骼" vs "自动匹配")。
   */
  isVrmDeclaredMappingAvailable(): boolean {
    if (this.autoMappingResult === null) {
      return false;
    }
    // VRM 映射的特征:profile 是 VRM0/VRM1 且至少一个 mapping 有 sourceNodeIndex >= 0
    if (this.autoMappingResult.profile !== SkeletonProfile.VRM0
      && this.autoMappingResult.profile !== SkeletonProfile.VRM1) {
      return false;
    }
    for (let i: number = 0; i < this.autoMappingResult.mappings.length; i++) {
      if (this.autoMappingResult.mappings[i].sourceNodeIndex >= 0) {
        return true;
      }
    }
    return false;
  }

  /**
   * 根据 node name 查找 node index。
   */
  private findNodeIndexByName(name: string): number {
    if (this.modelInfo === null) {
      return -1;
    }
    for (let i: number = 0; i < this.modelInfo.nodeNames.length; i++) {
      if (this.modelInfo.nodeNames[i] === name) {
        return i;
      }
    }
    return -1;
  }

  /**
   * 验证当前映射。
   *
   * @returns 验证结果
   */
  validate(): HumanoidMappingValidationResult {
    if (this.mapping === null) {
      this.validationResult = createEmptyValidationResult();
      return this.validationResult;
    }
    const input: HumanoidMappingValidatorInput = {
      mapping: this.mapping,
      totalNodeCount: this.getTotalNodeCount(),
      currentSkeletonHash: this.currentSkeletonHash,
      parentIndices: this.parentIndices,
      restPoses: [], // 暂不持有 rest pose,空间检查将跳过
      optionalBones: OPTIONAL_BONES,
      // T-3D.6F-A: 传入 skin joint nodeIndex 集合(简化:有 Skin 时所有 node 视为 joint)
      skinJointNodeIndices: this.buildSkinJointNodeIndices(),
      // T-3D.6F-A: sourceSha256(暂用空字符串,后续 Character3DService 提供时再启用)
      currentSourceSha256: ''
    };
    this.validationResult = validateHumanoidMapping(input);
    // 同步到 mapping 的 valid/retargetReady 字段
    this.mapping.valid = this.validationResult.valid;
    this.mapping.retargetReady = this.validationResult.retargetReady;
    Logger.info(LOG_TAG, 'validate: valid=' + this.validationResult.valid
      + ', errors=' + this.validationResult.errors.length
      + ', warnings=' + this.validationResult.warnings.length);
    return this.validationResult;
  }

  /**
   * T-3D.6F-A: 构造 skin.joints 对应的 nodeIndex 集合(简化版)。
   *
   * 当前 modelInfo 不持有完整 skin.joints 列表,简化为:
   * - 有 Skin 时返回 [0..nodeCount-1] 的全部索引(与 buildBoneTreeNodes 一致)
   * - 无 Skin 时返回空数组
   *
   * 后续如需精确判断,可扩展 GltfModelInfo 持有 skinJoints 字段。
   */
  private buildSkinJointNodeIndices(): number[] {
    if (this.modelInfo === null || !this.modelInfo.hasSkins) {
      return [];
    }
    const result: number[] = [];
    for (let i: number = 0; i < this.modelInfo.nodeCount; i++) {
      result.push(i);
    }
    return result;
  }

  /**
   * 保存当前映射到 Preferences。
   *
   * @returns true 保存成功
   */
  async save(): Promise<boolean> {
    if (this.mapping === null) {
      return false;
    }
    refreshMappingStats(this.mapping, REQUIRED_BONES, OPTIONAL_BONES);
    const ok: boolean = await this.mappingStore.save(this.mapping);
    return ok;
  }

  /**
   * 获取骨骼树节点列表(扁平,带缩进层级)。
   *
   * 简化版:不递归构建,直接按 nodeIndex 顺序输出。
   * 后续可扩展为真正的树形结构。
   */
  buildBoneTreeNodes(): BoneTreeNode[] {
    if (this.modelInfo === null || this.mapping === null) {
      return [];
    }
    const nodeNames: string[] = this.modelInfo.nodeNames;
    const result: BoneTreeNode[] = [];
    // 简化:无 parentIndices 时,所有节点都视为根
    for (let i: number = 0; i < nodeNames.length; i++) {
      const name: string = nodeNames[i];
      // 应用搜索过滤
      if (this.searchKeyword.length > 0
        && name.toLowerCase().indexOf(this.searchKeyword.toLowerCase()) < 0) {
        continue;
      }
      const binding: HumanoidJointBinding | null = this.findBindingBySourceIndex(i);
      result.push({
        nodeIndex: i,
        name: name.length > 0 ? name : '(node ' + i + ')',
        parentIndex: -1,
        children: [],
        isSkinJoint: this.modelInfo.hasSkins, // 简化:有 skin 时全部视为 joint
        isMapped: binding !== null,
        mappedTargetName: binding !== null ? getBoneDisplayName(binding.targetJoint) : '',
        level: 0
      });
    }
    return result;
  }

  /**
   * 根据 sourceNodeIndex 查找绑定。
   */
  private findBindingBySourceIndex(sourceNodeIndex: number): HumanoidJointBinding | null {
    if (this.mapping === null) {
      return null;
    }
    for (let i: number = 0; i < this.mapping.joints.length; i++) {
      if (this.mapping.joints[i].sourceNodeIndex === sourceNodeIndex) {
        return this.mapping.joints[i];
      }
    }
    return null;
  }

  /**
   * 获取摘要文案。
   */
  getSummaryText(): string {
    if (this.mapping === null) {
      return '尚未初始化';
    }
    let text: string = '已匹配 ' + this.mapping.joints.length + ' / ' + ALL_STANDARD_BONES.length;
    if (this.mapping.requiredMissing.length > 0) {
      text += ',缺必需 ' + this.mapping.requiredMissing.length;
    }
    if (this.validationResult.valid) {
      text += ',验证通过';
    } else if (this.validationResult.errors.length > 0) {
      text += ',验证失败';
    }
    return text;
  }

  /**
   * 获取验证问题列表(错误+警告)。
   */
  getAllIssues(): HumanoidMappingIssue[] {
    const all: HumanoidMappingIssue[] = [];
    for (let i: number = 0; i < this.validationResult.errors.length; i++) {
      all.push(this.validationResult.errors[i]);
    }
    for (let i: number = 0; i < this.validationResult.warnings.length; i++) {
      all.push(this.validationResult.warnings[i]);
    }
    return all;
  }

  // ==================== T-3D.6F-A: 表面点选 ====================

  /**
   * 是否支持表面点选(有 Skin + 有 GLB buffer)。
   */
  canSurfacePick(): boolean {
    return this.modelInfo !== null
      && this.modelInfo.hasSkins
      && this.glbBuffer !== null;
  }

  /**
   * 获取当前交互模式。
   */
  getInteractionMode(): MappingInteractionMode {
    return this.interactionMode;
  }

  /**
   * 获取当前候选列表。
   */
  getCurrentCandidates(): BoneClickCandidate[] {
    return this.currentCandidates;
  }

  /**
   * 获取已确认的候选索引。
   */
  getConfirmedCandidateIndex(): number {
    return this.confirmedCandidateIndex;
  }

  /**
   * 获取当前显示配置(供 UI 构造相机参数)。
   */
  getDisplayConfig(): Character3DDisplayConfig {
    return this.displayConfig;
  }

  /**
   * 进入表面点选模式。
   *
   * 前置条件:
   * - 已选中标准关节
   * - 模型有 Skin
   *
   * @returns true 进入成功
   */
  enterSurfacePickingMode(): boolean {
    if (this.selectedBone === null) {
      Logger.warn(LOG_TAG, 'enterSurfacePickingMode: no selectedBone');
      return false;
    }
    if (!this.canSurfacePick()) {
      Logger.warn(LOG_TAG, 'enterSurfacePickingMode: cannot surface pick');
      return false;
    }
    this.interactionMode = MappingInteractionMode.SurfacePicking;
    this.currentCandidates = [];
    this.confirmedCandidateIndex = -1;
    Logger.info(LOG_TAG, 'enterSurfacePickingMode: bone=' + this.selectedBone);
    return true;
  }

  /**
   * 取消表面点选,回到 Normal。
   *
   * 不修改已有映射,清除候选。
   */
  cancelSurfacePicking(): void {
    this.interactionMode = MappingInteractionMode.Normal;
    this.currentCandidates = [];
    this.confirmedCandidateIndex = -1;
    Logger.info(LOG_TAG, 'cancelSurfacePicking');
  }

  /**
   * 准备表面点选(解析 GLB 并构建世界空间三角形)。
   *
   * @returns true 准备成功
   */
  prepareSurfacePicking(): boolean {
    if (this.glbBuffer === null || !this.canSurfacePick()) {
      return false;
    }
    this.pickingService.setModelTransform(
      this.displayConfig.scale,
      this.displayConfig.offsetX,
      this.displayConfig.offsetY,
      this.displayConfig.offsetZ,
      this.displayConfig.rotationXDeg,
      this.displayConfig.rotationYDeg,
      this.displayConfig.rotationZDeg
    );
    return this.pickingService.prepare(this.glbBuffer);
  }

  /**
   * 执行表面点选。
   *
   * @param input 点选输入参数
   * @returns 候选 Bone 列表(已填充骨骼名),空数组表示未命中
   */
  pickSurfaceBone(input: SurfacePickingInput): BoneClickCandidate[] {
    if (!this.pickingService.isPrepared()) {
      Logger.warn(LOG_TAG, 'pickSurfaceBone: not prepared');
      return [];
    }
    const candidates: BoneClickCandidate[] = this.pickingService.pickBone(input);
    // 填充骨骼名
    const nodeNames: string[] = this.getNodeNames();
    for (let i: number = 0; i < candidates.length; i++) {
      const nodeIdx: number = candidates[i].nodeIndex;
      if (nodeIdx >= 0 && nodeIdx < nodeNames.length) {
        candidates[i].boneName = nodeNames[nodeIdx];
      } else {
        candidates[i].boneName = '(node ' + nodeIdx + ')';
      }
    }
    this.currentCandidates = candidates;
    this.confirmedCandidateIndex = -1;
    if (candidates.length > 0) {
      this.interactionMode = MappingInteractionMode.ConfirmCandidate;
    }
    Logger.info(LOG_TAG, 'pickSurfaceBone: candidates=' + candidates.length);
    return candidates;
  }

  /**
   * 选择候选(高亮对应骨骼,但不保存)。
   *
   * @param index 候选索引
   */
  selectCandidate(index: number): void {
    if (index < 0 || index >= this.currentCandidates.length) {
      return;
    }
    this.confirmedCandidateIndex = index;
    Logger.info(LOG_TAG, 'selectCandidate: idx=' + index
      + ', node=' + this.currentCandidates[index].nodeIndex);
  }

  /**
   * 确认当前选中的候选,保存为表面映射。
   *
   * 保存逻辑:
   * - 若该标准关节已有映射,询问 UI 是否替换(由 UI 调用 confirmReplace 传入 true)
   * - 新映射使用 BoneMappingMethod.ManualSurface
   * - confidence = 候选的 score
   *
   * @param replaceExisting 是否替换已有映射
   * @returns true 保存成功
   */
  confirmCandidate(replaceExisting: boolean): boolean {
    if (this.mapping === null || this.selectedBone === null) {
      return false;
    }
    if (this.confirmedCandidateIndex < 0
      || this.confirmedCandidateIndex >= this.currentCandidates.length) {
      return false;
    }
    // 检查是否已有映射
    const existing: HumanoidJointBinding | null = this.findBinding(this.selectedBone);
    if (existing !== null && !replaceExisting) {
      Logger.warn(LOG_TAG, 'confirmCandidate: existing binding, need replace');
      return false;
    }
    const candidate: BoneClickCandidate = this.currentCandidates[this.confirmedCandidateIndex];
    // 验证候选
    const validationError: string = this.validateSurfaceCandidate(candidate);
    if (validationError.length > 0) {
      Logger.warn(LOG_TAG, 'confirmCandidate: validation failed: ' + validationError);
      return false;
    }
    const binding: HumanoidJointBinding = {
      targetJoint: this.selectedBone,
      sourceNodeIndex: candidate.nodeIndex,
      sourceBoneName: candidate.boneName,
      mappingMethod: BoneMappingMethod.ManualSurface,
      confidence: candidate.score
    };
    setJointBinding(this.mapping, binding);
    refreshMappingStats(this.mapping, REQUIRED_BONES, OPTIONAL_BONES);
    // 同步选中源骨骼
    this.selectedSourceNodeIndex = candidate.nodeIndex;
    this.interactionMode = MappingInteractionMode.Normal;
    this.currentCandidates = [];
    this.confirmedCandidateIndex = -1;
    Logger.info(LOG_TAG, 'confirmCandidate: saved bone=' + this.selectedBone
      + ' → node=' + candidate.nodeIndex);
    return true;
  }

  /**
   * 检查当前选中的标准关节是否已有映射(用于 UI 询问是否替换)。
   */
  hasExistingBindingForSelectedBone(): boolean {
    if (this.mapping === null || this.selectedBone === null) {
      return false;
    }
    return this.findBinding(this.selectedBone) !== null;
  }

  /**
   * 验证表面点选候选。
   *
   * 检查:
   * 1. nodeIndex 存在(在 nodes 范围内)
   * 2. 属于当前 Skin(在 skin.joints 中)
   * 3. 不是重复 Bone(同一 nodeIndex 未被其他标准关节映射,除非允许替换)
   *
   * @returns 错误信息,空字符串表示通过
   */
  private validateSurfaceCandidate(candidate: BoneClickCandidate): string {
    if (this.modelInfo === null) {
      return 'modelInfo 为 null';
    }
    // 1. nodeIndex 存在
    if (candidate.nodeIndex < 0 || candidate.nodeIndex >= this.modelInfo.nodeCount) {
      return 'nodeIndex 超出范围: ' + candidate.nodeIndex;
    }
    // 2. 属于当前 Skin(简化:有 Skin 时全部视为 joint,与 buildBoneTreeNodes 一致)
    if (!this.modelInfo.hasSkins) {
      return '模型无 Skin';
    }
    // 3. 不是重复 Bone(检查是否已被其他标准关节映射)
    if (this.mapping !== null) {
      for (let i: number = 0; i < this.mapping.joints.length; i++) {
        const b: HumanoidJointBinding = this.mapping.joints[i];
        if (b.sourceNodeIndex === candidate.nodeIndex && b.targetJoint !== this.selectedBone) {
          return 'nodeIndex ' + candidate.nodeIndex + ' 已被 ' + b.targetJoint + ' 映射';
        }
      }
    }
    return '';
  }
}

/**
 * 计算可选骨骼列表。
 */
function computeOptionalBones(): HumanoidBone[] {
  const optional: HumanoidBone[] = [];
  for (let i: number = 0; i < ALL_STANDARD_BONES.length; i++) {
    if (REQUIRED_BONES.indexOf(ALL_STANDARD_BONES[i]) < 0) {
      optional.push(ALL_STANDARD_BONES[i]);
    }
  }
  return optional;
}

/**
 * 标准关节中文名。
 */
export function getBoneDisplayName(bone: HumanoidBone): string {
  switch (bone) {
    case HumanoidBone.Hips: return '髋部';
    case HumanoidBone.Spine: return '脊柱';
    case HumanoidBone.Chest: return '胸部';
    case HumanoidBone.UpperChest: return '上胸部';
    case HumanoidBone.Neck: return '颈部';
    case HumanoidBone.Head: return '头部';
    case HumanoidBone.LeftShoulder: return '左肩';
    case HumanoidBone.LeftUpperArm: return '左上臂';
    case HumanoidBone.LeftLowerArm: return '左前臂';
    case HumanoidBone.LeftHand: return '左手';
    case HumanoidBone.RightShoulder: return '右肩';
    case HumanoidBone.RightUpperArm: return '右上臂';
    case HumanoidBone.RightLowerArm: return '右前臂';
    case HumanoidBone.RightHand: return '右手';
    case HumanoidBone.LeftUpperLeg: return '左大腿';
    case HumanoidBone.LeftLowerLeg: return '左小腿';
    case HumanoidBone.LeftFoot: return '左脚';
    case HumanoidBone.LeftToes: return '左脚趾';
    case HumanoidBone.RightUpperLeg: return '右大腿';
    case HumanoidBone.RightLowerLeg: return '右小腿';
    case HumanoidBone.RightFoot: return '右脚';
    case HumanoidBone.RightToes: return '右脚趾';
    case HumanoidBone.LeftEye: return '左眼';
    case HumanoidBone.RightEye: return '右眼';
    case HumanoidBone.Jaw: return '下巴';
    default: return bone;
  }
}
