/**
 * ModelExtensionCompatibilityRegistry 模型扩展兼容性集中配置
 *
 * T-3D.6D: 模型导入稳定性、兼容性诊断与自动验收
 *
 * 职责:
 * - 集中定义 glTF 扩展的兼容性分类
 * - 提供统一的扩展判定 API(isDirectlySupported / isConvertible / isUnsupported)
 * - 禁止在 GltfValidator / GltfSemanticValidator / CompatibilityService 各处分散定义
 *
 * 分类:
 * 1. 直接支持(DirectlySupported): ArkGraphics 原生支持,无需转换
 * 2. 可转换(Convertible): 通过预处理管线转换为标准 GLB
 * 3. 不支持(Unsupported): 当前版本无法处理,required 时拒绝
 *
 * 重要:
 * - 根据 ArkGraphics 当前真实能力确认,不得猜测
 * - KHR_mesh_quantization: 保留策略,只要 ArkGraphics 支持或标准 glTF 允许就保留
 * - 不得无依据删除 KHR_mesh_quantization
 */

/**
 * 扩展兼容性分类。
 */
export enum ExtensionCompatibility {
  /** 直接支持(ArkGraphics 原生) */
  DirectlySupported = 0,
  /** 可转换(如 EXT_meshopt_compression) */
  Convertible = 1,
  /** 不支持(如 KHR_draco_mesh_compression) */
  Unsupported = 2,
  /** 未知扩展 */
  Unknown = 3
}

/**
 * 直接支持的扩展列表。
 *
 * ArkGraphics 3D 已验证可原生加载的扩展。
 * 根据项目实际测试结果维护,不得凭猜测添加。
 */
const DIRECTLY_SUPPORTED_EXTENSIONS: string[] = [
  // ArkGraphics 原生支持的材质扩展
  'KHR_materials_unlit',
  // 纹理变换扩展
  'KHR_texture_transform',
  // 灯光扩展
  'KHR_lights_punctual',
  // 网格量化扩展(保留策略:ArkGraphics 已验证支持)
  'KHR_mesh_quantization'
];

/**
 * 可转换的扩展列表。
 *
 * 通过预处理管线(NAPI meshopt 解码器)转换为标准 GLB 2.0。
 */
const CONVERTIBLE_EXTENSIONS: string[] = [
  // meshopt 压缩扩展,通过 meshoptimizer 解码
  'EXT_meshopt_compression'
];

/**
 * 不支持的扩展列表。
 *
 * 当前版本无法处理,若出现在 extensionsRequired 中则拒绝导入。
 */
const UNSUPPORTED_EXTENSIONS: string[] = [
  // Draco 网格压缩,未实现解码器
  'KHR_draco_mesh_compression',
  // BasisU 纹理压缩,未实现解码器
  'KHR_texture_basisu',
  // 材质清漆层扩展,ArkGraphics 未验证
  'KHR_materials_clearcoat',
  // 材质体积扩展,ArkGraphics 未验证
  'KHR_materials_volume',
  // 材质折射扩展,ArkGraphics 未验证
  'KHR_materials_ior',
  // 材质光泽扩展,ArkGraphics 未验证
  'KHR_materials_specular',
  // 材质透射扩展,ArkGraphics 未验证
  'KHR_materials_transmission',
  // 材质自发光强度扩展,ArkGraphics 未验证
  'KHR_materials_emissive_strength',
  // 材质虹彩扩展,ArkGraphics 未验证
  'KHR_materials_iridescence',
  // 材质剪切扩展,ArkGraphics 未验证
  'KHR_materials_sheen'
];

/**
 * 模型扩展兼容性注册表。
 *
 * 所有扩展判定必须通过此注册表,禁止在多处分散定义。
 */
export class ModelExtensionCompatibilityRegistry {
  /**
   * 判断扩展是否直接支持。
   */
  static isDirectlySupported(ext: string): boolean {
    return DIRECTLY_SUPPORTED_EXTENSIONS.indexOf(ext) >= 0;
  }

  /**
   * 判断扩展是否可转换。
   */
  static isConvertible(ext: string): boolean {
    return CONVERTIBLE_EXTENSIONS.indexOf(ext) >= 0;
  }

  /**
   * 判断扩展是否不支持。
   */
  static isUnsupported(ext: string): boolean {
    return UNSUPPORTED_EXTENSIONS.indexOf(ext) >= 0;
  }

  /**
   * 获取扩展的兼容性分类。
   */
  static getClassification(ext: string): ExtensionCompatibility {
    if (ModelExtensionCompatibilityRegistry.isDirectlySupported(ext)) {
      return ExtensionCompatibility.DirectlySupported;
    }
    if (ModelExtensionCompatibilityRegistry.isConvertible(ext)) {
      return ExtensionCompatibility.Convertible;
    }
    if (ModelExtensionCompatibilityRegistry.isUnsupported(ext)) {
      return ExtensionCompatibility.Unsupported;
    }
    return ExtensionCompatibility.Unknown;
  }

  /**
   * 获取直接支持的扩展列表(只读副本)。
   */
  static getDirectlySupportedExtensions(): string[] {
    return DIRECTLY_SUPPORTED_EXTENSIONS.slice();
  }

  /**
   * 获取可转换的扩展列表(只读副本)。
   */
  static getConvertibleExtensions(): string[] {
    return CONVERTIBLE_EXTENSIONS.slice();
  }

  /**
   * 获取不支持的扩展列表(只读副本)。
   */
  static getUnsupportedExtensions(): string[] {
    return UNSUPPORTED_EXTENSIONS.slice();
  }

  /**
   * 判断 extensionsRequired 中是否存在不支持的扩展。
   *
   * @param extensionsRequired 必需扩展列表
   * @returns 不支持的必需扩展列表(空表示全部可处理)
   */
  static findUnsupportedRequired(extensionsRequired: string[]): string[] {
    const result: string[] = [];
    for (let i: number = 0; i < extensionsRequired.length; i++) {
      const ext: string = extensionsRequired[i];
      if (ModelExtensionCompatibilityRegistry.isUnsupported(ext)) {
        result.push(ext);
      }
    }
    return result;
  }

  /**
   * 判断 extensionsRequired 中是否存在可转换的扩展。
   *
   * @param extensionsRequired 必需扩展列表
   * @returns 可转换的必需扩展列表
   */
  static findConvertibleRequired(extensionsRequired: string[]): string[] {
    const result: string[] = [];
    for (let i: number = 0; i < extensionsRequired.length; i++) {
      const ext: string = extensionsRequired[i];
      if (ModelExtensionCompatibilityRegistry.isConvertible(ext)) {
        result.push(ext);
      }
    }
    return result;
  }

  /**
   * 判断 extensionsUsed 中是否存在可转换的扩展。
   *
   * @param extensionsUsed 使用扩展列表
   * @returns 可转换的使用扩展列表
   */
  static findConvertibleUsed(extensionsUsed: string[]): string[] {
    const result: string[] = [];
    for (let i: number = 0; i < extensionsUsed.length; i++) {
      const ext: string = extensionsUsed[i];
      if (ModelExtensionCompatibilityRegistry.isConvertible(ext)) {
        result.push(ext);
      }
    }
    return result;
  }

  /**
   * 判断 extensionsUsed 中是否存在直接支持的扩展。
   *
   * @param extensionsUsed 使用扩展列表
   * @returns 直接支持的使用扩展列表
   */
  static findDirectlySupportedUsed(extensionsUsed: string[]): string[] {
    const result: string[] = [];
    for (let i: number = 0; i < extensionsUsed.length; i++) {
      const ext: string = extensionsUsed[i];
      if (ModelExtensionCompatibilityRegistry.isDirectlySupported(ext)) {
        result.push(ext);
      }
    }
    return result;
  }
}
