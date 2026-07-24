/**
 * SceneNodeCollector Scene 节点收集器
 *
 * T-4.2E: 建立 ArkGraphics3D SceneNode 与 glTF nodeIndex 的映射。
 *
 * 背景:
 * - ArkGraphics3D Scene.load 后,只能通过 scene.root 遍历 SceneNode 树
 * - SceneNode 没有保存 glTF nodeIndex 字段
 * - VRM HumanoidProvider 返回的 nodeIndex 是 glTF JSON 中 nodes 数组的下标
 * - 因此需要建立 nodeIndex → SceneNode 的桥接
 *
 * 策略:
 * 1. 解析 Avatar GLB 的 JSON,获取 nodes 数组(每个 node 带 name)
 * 2. 遍历 SceneNode 树,收集 name → SceneNode 映射
 * 3. 通过 nodes[nodeIndex].name 在 name → SceneNode 中查找
 *
 * 唯一性保证:
 * - VRM 标准要求每个骨骼节点名唯一
 * - 若出现重名,取第一个匹配(并记录警告)
 */

import { Scene, Node } from '@kit.ArkGraphics3D';
import { parseGlb, GlbParsedData } from '../parser/GltfVertexAccessor';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'SceneNodeCollector';

/**
 * 节点收集结果。
 */
export interface SceneNodeCollectResult {
  /** 是否成功 */
  success: boolean;
  /** 错误信息 */
  errorMessage: string;
  /** nodeIndex → SceneNode 映射 */
  nodeIndexMap: Map<number, Node>;
  /** bone name → SceneNode 映射(用于按名查找) */
  nameMap: Map<string, Node>;
  /** 收集到的节点总数 */
  totalNodes: number;
  /** 重名警告列表 */
  warnings: string[];
}

/**
 * 收集 Scene 中的所有节点,并建立 nodeIndex → SceneNode 映射。
 *
 * @param scene ArkGraphics3D Scene
 * @param glbBuffer Avatar GLB 文件的 ArrayBuffer(用于读取 nodes 数组)
 * @returns 收集结果
 */
export function collectSceneNodes(
  scene: Scene,
  glbBuffer: ArrayBuffer
): SceneNodeCollectResult {
  // 1. 解析 GLB JSON,获取 nodes 数组
  const parsed: GlbParsedData = parseGlb(glbBuffer);
  if (!parsed.valid) {
    return {
      success: false,
      errorMessage: 'GLB 解析失败: ' + parsed.errorMessage,
      nodeIndexMap: new Map<number, Node>(),
      nameMap: new Map<string, Node>(),
      totalNodes: 0,
      warnings: []
    };
  }

  const nodes: Object[] | undefined = parsed.json['nodes'] as Object[] | undefined;
  if (nodes === undefined) {
    return {
      success: false,
      errorMessage: 'GLB 缺少 nodes 数组',
      nodeIndexMap: new Map<number, Node>(),
      nameMap: new Map<string, Node>(),
      totalNodes: 0,
      warnings: []
    };
  }

  // 2. 遍历 SceneNode 树,收集 name → SceneNode 映射
  const sceneRoot: Node | null = scene.root;
  if (sceneRoot === null) {
    return {
      success: false,
      errorMessage: 'scene.root 为 null',
      nodeIndexMap: new Map<number, Node>(),
      nameMap: new Map<string, Node>(),
      totalNodes: 0,
      warnings: []
    };
  }

  const nameMap: Map<string, Node> = new Map<string, Node>();
  const warnings: string[] = [];
  let totalNodes: number = 0;
  traverseAndCollect(sceneRoot, nameMap, warnings, (count: number) => {
    totalNodes = count;
  });

  Logger.info(LOG_TAG, 'collectSceneNodes: scene nodes=' + totalNodes
    + ', glb nodes=' + nodes.length
    + ', unique names=' + nameMap.size);

  // 3. 建立 nodeIndex → SceneNode 映射
  const nodeIndexMap: Map<number, Node> = new Map<number, Node>();
  let matched: number = 0;
  for (let i: number = 0; i < nodes.length; i++) {
    const node: Record<string, Object> = nodes[i] as Record<string, Object>;
    const nameObj: Object | undefined = node['name'];
    if (nameObj === undefined || nameObj === null) {
      continue;
    }
    const name: string = String(nameObj);
    if (name.length === 0) {
      continue;
    }
    const sceneNode: Node | undefined = nameMap.get(name);
    if (sceneNode !== undefined) {
      nodeIndexMap.set(i, sceneNode);
      matched++;
    }
  }

  Logger.info(LOG_TAG, 'collectSceneNodes: nodeIndexMap built, matched=' + matched
    + '/' + nodes.length);

  return {
    success: true,
    errorMessage: '',
    nodeIndexMap: nodeIndexMap,
    nameMap: nameMap,
    totalNodes: totalNodes,
    warnings: warnings
  };
}

/**
 * 递归遍历 SceneNode 树,收集 name → Node 映射。
 */
function traverseAndCollect(
  node: Node,
  nameMap: Map<string, Node>,
  warnings: string[],
  onCount: (count: number) => void
): void {
  let count: number = 0;
  traverseInternal(node, nameMap, warnings, (c: number) => {
    count = c;
  });
  onCount(count);
}

/**
 * 内部递归遍历。
 */
function traverseInternal(
  node: Node,
  nameMap: Map<string, Node>,
  warnings: string[],
  onCount: (count: number) => void
): void {
  let count: number = 1;
  try {
    const name: string = node.name;
    if (name.length > 0) {
      if (nameMap.has(name)) {
        warnings.push('重名节点: ' + name);
      } else {
        nameMap.set(name, node);
      }
    }
  } catch (_e) {
    // ignore
  }
  try {
    const children = node.children;
    const childCount: number = children.count();
    for (let i: number = 0; i < childCount; i++) {
      const child: Node | null = children.get(i);
      if (child !== null) {
        let childCount2: number = 0;
        traverseInternal(child, nameMap, warnings, (c: number) => {
          childCount2 = c;
        });
        count += childCount2;
      }
    }
  } catch (_e) {
    // ignore
  }
  onCount(count);
}

/**
 * 按节点名查找 SceneNode。
 *
 * @param nameMap name → SceneNode 映射
 * @param name 节点名
 * @returns SceneNode 或 null
 */
export function findNodeByName(
  nameMap: Map<string, Node>,
  name: string
): Node | null {
  const node: Node | undefined = nameMap.get(name);
  if (node !== undefined) {
    return node;
  }
  return null;
}

/**
 * 按 nodeIndex 查找 SceneNode。
 *
 * @param nodeIndexMap nodeIndex → SceneNode 映射
 * @param nodeIndex glTF node 索引
 * @returns SceneNode 或 null
 */
export function findNodeByIndex(
  nodeIndexMap: Map<number, Node>,
  nodeIndex: number
): Node | null {
  const node: Node | undefined = nodeIndexMap.get(nodeIndex);
  if (node !== undefined) {
    return node;
  }
  return null;
}
