/**
 * ViewerResourceDisposer VRM Viewer 资源释放器
 *
 * 负责递归遍历模型节点树,释放 Material/Mesh/Image 等关联资源,
 * 最后 destroy 节点本身。同时提供半初始化对象清理。
 *
 * Reference:
 * - figure-main: index.html L849–896 (disposeVrm: 递归 traverse 释放
 *   geometry/material.map/material)
 * - ownverse-vrm-viewer: analysis/RESOURCE_LIFECYCLE.md (Avatar.dispose
 *   不调用 deepDispose 的已知泄漏;Path A whole-avatar swap)
 *
 * 关键差异:
 * - ArkGraphics3D 资源 API 是 `destroy()` 而非 `dispose()`。
 * - Material/Mesh/Image/Node 均继承自 SceneResource.destroy()。
 * - 本实现采用 Figure 的显式递归遍历,避免 OWNverse 已知泄漏。
 */

import {
  Geometry,
  Material,
  Mesh,
  Node,
  NodeType,
  Scene,
  SceneResource
} from '@kit.ArkGraphics3D';

/**
 * 资源释放器。
 *
 * 所有方法均为幂等(重复调用不崩溃)。
 */
export class ViewerResourceDisposer {
  /**
   * 释放模型节点树。
   *
   * 步骤:
   * 1. 若 node == null,直接返回。
   * 2. 从父节点移除(若存在)。
   * 3. 递归遍历子节点,对每个 Geometry 节点释放关联 Material 与 Mesh。
   * 4. destroy 节点本身。
   *
   * @param node 模型根节点(可为 null)
   */
  public disposeModel(node: Node | null): void {
    if (node === null) {
      return;
    }

    // 1. 从父节点移除
    const parent = node.parent;
    if (parent !== null) {
      try {
        parent.children.remove(node);
      } catch (_) {
        // 忽略
      }
    }

    // 2. 递归释放子树
    this.disposeNodeTree(node);
  }

  /**
   * 清理半初始化的模型资源(加载失败时调用)。
   *
   * @param scene 加载到一半的 Scene(可为 null)
   * @param node 已挂载的节点(可为 null)
   */
  public cleanupHalfInitialized(scene: Scene | null, node: Node | null): void {
    if (node !== null) {
      this.disposeModel(node);
    }
    if (scene !== null) {
      try {
        scene.destroy();
      } catch (_) {
        // 忽略
      }
    }
  }

  /**
   * 递归释放节点树。
   *
   * @param node 当前节点
   */
  private disposeNodeTree(node: Node): void {
    // 先递归子节点
    const children = node.children;
    const count = children.count();
    for (let i = 0; i < count; i++) {
      const child = children.get(i);
      if (child !== null) {
        this.disposeNodeTree(child);
      }
    }

    // 按节点类型释放关联资源
    if (node.nodeType === NodeType.GEOMETRY) {
      const geom = node as Geometry;
      // 释放 Mesh 及其 SubMesh 的 Material
      const mesh = geom.mesh;
      if (mesh !== null && mesh !== undefined) {
        const subMeshes = mesh.subMeshes;
        if (subMeshes !== null && subMeshes !== undefined) {
          for (let i = 0; i < subMeshes.length; i++) {
            const subMesh = subMeshes[i];
            const mat = subMesh.material;
            if (mat !== null && mat !== undefined) {
              this.destroySceneResource(mat);
            }
          }
        }
        this.destroySceneResource(mesh);
      }
    }

    // 最后 destroy 节点本身
    this.destroyNode(node);
  }

  /**
   * 销毁 SceneResource(Material/Mesh/Image 等),捕获异常。
   *
   * @param res 资源对象
   */
  private destroySceneResource(res: SceneResource): void {
    try {
      res.destroy();
    } catch (_) {
      // 忽略重复销毁
    }
  }

  /**
   * 销毁 Node,捕获异常。
   *
   * @param node 节点
   */
  private destroyNode(node: Node): void {
    try {
      node.destroy();
    } catch (_) {
      // 忽略重复销毁
    }
  }
}
