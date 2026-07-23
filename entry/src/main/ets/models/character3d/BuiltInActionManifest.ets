/**
 * BuiltInActionManifest 内置动作包清单模型
 *
 * T-3D.6C: 从 rawfile 读取 default_ai_action_pack.json,解析内置动作元数据。
 *
 * 内置动作始终随 App 安装,不依赖网络下载或用户导入。
 * 清空 Preferences 后重新加载仍可恢复。
 */

/**
 * 内置动作清单(从 rawfile JSON 解析)。
 */
export interface BuiltInActionManifest {
  /** 清单版本 */
  version: string;
  /** 骨骼 Profile 标识 */
  skeletonProfile: string;
  /** 动作包 GLB 文件名(rawfile 内相对路径) */
  packFile: string;
  /** 预览模型 GLB 文件名(rawfile 内相对路径) */
  previewModelFile: string;
  /** 动作条目列表 */
  actions: BuiltInActionEntry[];
}

/**
 * 内置动作条目。
 */
export interface BuiltInActionEntry {
  /** 稳定 ID(如 builtin_idle) */
  id: string;
  /** 目标动作槽位 */
  slot: string;
  /** GLB 内 Clip 名称(如 AT_Idle) */
  clipName: string;
  /** 默认显示名(中文) */
  defaultDisplayName: string;
  /** 时长(毫秒) */
  durationMs: number;
  /** 是否循环 */
  loop: boolean;
  /** 排序序号 */
  sortOrder: number;
  /** 缩略图路径(rawfile 内相对路径) */
  thumbnailPath: string;
  /** 分类(base/social/emotion/reaction) */
  category: string;
  /** 是否内置(始终为 true) */
  builtIn: boolean;
  /** 必需骨骼列表 */
  requiredBones: string[];
  /** 缺失时的回退 Clip 名称(null 表示无回退) */
  fallbackSlot: string | null;
}

/**
 * rawfile 内置动作根目录。
 */
export const BUILTIN_ACTION_RAWFILE_DIR: string = 'actions/default_ai';

/**
 * 内置动作清单文件名。
 */
export const BUILTIN_MANIFEST_FILE_NAME: string = 'default_ai_action_pack.json';

/**
 * 内置动作包 GLB 文件名。
 */
export const BUILTIN_PACK_FILE_NAME: string = 'default_ai_action_pack.glb';

/**
 * 预览模型 GLB 文件名。
 */
export const BUILTIN_PREVIEW_FILE_NAME: string = 'preview_humanoid.glb';

/**
 * 内置动作在沙盒中的共享目录(相对于 filesDir)。
 * 所有内置动作共享同一个 GLB 文件。
 */
export const BUILTIN_PACK_SANDBOX_DIR: string = 'character_actions/builtin_pack';

/**
 * 解析 JSON 字符串为内置动作清单。
 * 解析失败时返回 null。
 */
export function parseBuiltInManifest(json: string): BuiltInActionManifest | null {
  try {
    const obj: Record<string, Object> = JSON.parse(json) as Record<string, Object>;
    const version: string = String(obj['version'] ?? '');
    const skeletonProfile: string = String(obj['skeletonProfile'] ?? '');
    const packFile: string = String(obj['packFile'] ?? '');
    const previewModelFile: string = String(obj['previewModelFile'] ?? '');
    const rawActions: Object[] = obj['actions'] as Object[];
    if (!Array.isArray(rawActions)) {
      return null;
    }
    const actions: BuiltInActionEntry[] = [];
    for (let i: number = 0; i < rawActions.length; i++) {
      const item: Record<string, Object> = rawActions[i] as Record<string, Object>;
      const fallbackSlot: Object | undefined = item['fallbackSlot'];
      actions.push({
        id: String(item['id'] ?? ''),
        slot: String(item['slot'] ?? ''),
        clipName: String(item['clipName'] ?? ''),
        defaultDisplayName: String(item['defaultDisplayName'] ?? ''),
        durationMs: Number(item['durationMs'] ?? 0),
        loop: Boolean(item['loop'] ?? false),
        sortOrder: Number(item['sortOrder'] ?? 0),
        thumbnailPath: String(item['thumbnailPath'] ?? ''),
        category: String(item['category'] ?? ''),
        builtIn: Boolean(item['builtIn'] ?? true),
        requiredBones: (item['requiredBones'] as string[]) ?? [],
        fallbackSlot: fallbackSlot === null || fallbackSlot === undefined ? null : String(fallbackSlot),
      });
    }
    return {
      version,
      skeletonProfile,
      packFile,
      previewModelFile,
      actions,
    };
  } catch (e) {
    return null;
  }
}
