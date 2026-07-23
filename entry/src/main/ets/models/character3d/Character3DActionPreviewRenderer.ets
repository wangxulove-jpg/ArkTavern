/**
 * Character3DActionPreviewRenderer 动作预览 Canvas 绘制器
 *
 * T-3D.6C-B: 修复黑屏问题,版本3。
 *
 * 关键发现(经像素分析证实):
 * 1. ArkUI Canvas 路径 API(beginPath/arc/moveTo/lineTo/stroke/fill)不产生可见输出。
 * 2. ArkUI Canvas fillRect/strokeRect 使用非整数坐标时不产生可见输出。
 * 3. ArkUI Canvas save/translate/rotate 变换不可靠。
 *
 * 版本3 策略:
 * - 全部坐标使用 Math.round() 取整。
 * - 骨骼连线使用 drawLineWithRects(沿连线步进绘制整数 fillRect 小方块),
 *   替代 save/translate/rotate/fillRect。
 * - 关节、头部使用整数 fillRect / strokeRect。
 *
 * 坐标系:
 * - 骨架使用 0~100 逻辑空间(原点左上,Y 轴向下)
 * - Renderer 内部统一转换:drawX = round(offsetX + logicalX * scale)
 * - scale = min(canvasWidth, canvasHeight) / 100
 * - Canvas 绘图坐标使用 vp(由 ActionPreviewCanvas 传入 vp 值)
 */

import { BonePoseFrame } from './ActionPreviewKeyframes';
import {
  ComputedJoint,
  computeSkeletonJoints,
  DEFAULT_HUMANOID_SKELETON,
  SkeletonNodeDef
} from './DefaultHumanoidSkeleton';

/** 调试模式开关(验收通过后关闭) */
const ACTION_PREVIEW_DEBUG: boolean = false;

// ========== 高对比度颜色(浅色模式) ==========

const COLOR_BG_LIGHT: string = '#F2F3F5';
const COLOR_BONE_LIGHT: string = '#202124';
const COLOR_JOINT_LIGHT: string = '#2F73FF';
const COLOR_HEAD_FILL_LIGHT: string = '#FFFFFF';
const COLOR_HEAD_STROKE_LIGHT: string = '#202124';

// ========== 高对比度颜色(深色模式) ==========

const COLOR_BG_DARK: string = '#26282D';
const COLOR_BONE_DARK: string = '#F5F5F5';
const COLOR_JOINT_DARK: string = '#7B9BFF';
const COLOR_HEAD_FILL_DARK: string = '#363940';
const COLOR_HEAD_STROKE_DARK: string = '#F5F5F5';

// ========== 调试色 ==========

const COLOR_DEBUG_BORDER: string = '#FF0000';
const COLOR_DEBUG_CIRCLE: string = '#2F73FF';
const COLOR_DEBUG_LINE: string = '#00C853';
const COLOR_DEBUG_TEXT_BG: string = 'rgba(0,0,0,0.65)';
const COLOR_DEBUG_TEXT: string = '#FFFFFF';

/**
 * 骨骼连接对(在两个关节之间绘制线段)。
 */
interface BoneConnection {
  parent: string;
  child: string;
}

const BONE_CONNECTIONS: BoneConnection[] = [
  { parent: 'Head', child: 'Neck' },
  { parent: 'Neck', child: 'Spine' },
  { parent: 'Spine', child: 'Hips' },
  { parent: 'Spine', child: 'LeftShoulder' },
  { parent: 'LeftShoulder', child: 'LeftArm' },
  { parent: 'LeftArm', child: 'LeftHand' },
  { parent: 'Spine', child: 'RightShoulder' },
  { parent: 'RightShoulder', child: 'RightArm' },
  { parent: 'RightArm', child: 'RightHand' },
  { parent: 'Hips', child: 'LeftLeg' },
  { parent: 'LeftLeg', child: 'LeftFoot' },
  { parent: 'Hips', child: 'RightLeg' },
  { parent: 'RightLeg', child: 'RightFoot' }
];

/**
 * 渲染模式(浅色/深色)。
 */
export enum PreviewColorMode {
  Light,
  Dark
}

/**
 * 检查坐标点是否为有限数值。
 */
export function isFinitePoint(x: number, y: number): boolean {
  return Number.isFinite(x) && Number.isFinite(y);
}

/**
 * 校验骨架定义是否合法。
 */
export function validateSkeletonDefinition(): string | null {
  const names: string[] = [];
  let rootCount: number = 0;
  for (let i: number = 0; i < DEFAULT_HUMANOID_SKELETON.length; i++) {
    const node: SkeletonNodeDef = DEFAULT_HUMANOID_SKELETON[i];
    let isDuplicate: boolean = false;
    for (let j: number = 0; j < names.length; j++) {
      if (names[j] === node.name) {
        isDuplicate = true;
        break;
      }
    }
    if (isDuplicate) {
      return 'duplicate bone name: ' + node.name;
    }
    names.push(node.name);
    if (node.parent === null) {
      rootCount++;
    } else {
      let parentFound: boolean = false;
      for (let j: number = 0; j < names.length; j++) {
        if (names[j] === node.parent) {
          parentFound = true;
          break;
        }
      }
      if (!parentFound) {
        return 'parent not defined before child: ' + node.name + ' -> ' + node.parent;
      }
    }
  }
  if (rootCount !== 1) {
    return 'expected 1 root, got ' + rootCount.toString();
  }
  return null;
}

/**
 * 动作预览渲染器。
 *
 * 版本3:全部使用整数坐标 fillRect/strokeRect + drawLineWithRects。
 */
export class Character3DActionPreviewRenderer {
  private context: CanvasRenderingContext2D;
  private width: number;
  private height: number;
  private colorMode: PreviewColorMode = PreviewColorMode.Light;

  constructor(context: CanvasRenderingContext2D, width: number, height: number) {
    this.context = context;
    this.width = Math.round(width);
    this.height = Math.round(height);
  }

  resize(width: number, height: number): void {
    this.width = Math.round(width);
    this.height = Math.round(height);
  }

  setColorMode(mode: PreviewColorMode): void {
    this.colorMode = mode;
  }

  private getBgColor(): string {
    return this.colorMode === PreviewColorMode.Dark ? COLOR_BG_DARK : COLOR_BG_LIGHT;
  }

  private getBoneColor(): string {
    return this.colorMode === PreviewColorMode.Dark ? COLOR_BONE_DARK : COLOR_BONE_LIGHT;
  }

  private getJointColor(): string {
    return this.colorMode === PreviewColorMode.Dark ? COLOR_JOINT_DARK : COLOR_JOINT_LIGHT;
  }

  private getHeadFillColor(): string {
    return this.colorMode === PreviewColorMode.Dark ? COLOR_HEAD_FILL_DARK : COLOR_HEAD_FILL_LIGHT;
  }

  private getHeadStrokeColor(): string {
    return this.colorMode === PreviewColorMode.Dark ? COLOR_HEAD_STROKE_DARK : COLOR_HEAD_STROKE_LIGHT;
  }

  /**
   * 清空画布并绘制背景。
   */
  drawBackground(): void {
    const ctx: CanvasRenderingContext2D = this.context;
    ctx.globalAlpha = 1;
    ctx.clearRect(0, 0, this.width, this.height);
    ctx.fillStyle = this.getBgColor();
    ctx.fillRect(0, 0, this.width, this.height);
  }

  /**
   * 静态基线测试绘制。
   */
  drawTestBaseline(): void {
    this.drawBackground();
    this.drawDebugBorder();
    const tPose: BonePoseFrame = {
      timestamp: 0,
      rotations: [],
      rootOffsetX: 0,
      rootOffsetY: 0
    };
    this.drawPose(tPose);
  }

  /**
   * 绘制调试边框(红框 + 中心方块 + 竖线)。
   * 全部使用整数坐标 fillRect/strokeRect。
   */
  drawDebugBorder(): void {
    const ctx: CanvasRenderingContext2D = this.context;
    ctx.globalAlpha = 1;

    // 红色边框(strokeRect)
    ctx.strokeStyle = COLOR_DEBUG_BORDER;
    ctx.lineWidth = 3;
    ctx.strokeRect(2, 2, this.width - 4, this.height - 4);

    // 蓝色中心方块(fillRect,整数坐标)
    const cx: number = Math.round(this.width / 2);
    const cy: number = Math.round(this.height / 2);
    const r: number = Math.round(Math.min(this.width, this.height) * 0.12);
    ctx.fillStyle = COLOR_DEBUG_CIRCLE;
    ctx.fillRect(cx - r, cy - r, r * 2, r * 2);

    // 绿色竖线(fillRect,整数坐标)
    ctx.fillStyle = COLOR_DEBUG_LINE;
    ctx.fillRect(cx - 1, 0, 2, this.height);
  }

  /**
   * 绘制指定姿态的骨架。
   *
   * 版本3:
   * - 骨骼使用 drawLineWithRects(沿连线步进绘制整数小方块)
   * - 关节使用整数 fillRect
   * - 头部使用整数 fillRect + strokeRect
   *
   * @param pose 当前帧的骨骼姿态
   * @returns 无效关节数量(用于调试)
   */
  drawPose(pose: BonePoseFrame): number {
    const ctx: CanvasRenderingContext2D = this.context;
    ctx.globalAlpha = 1;

    // 1. 计算关节坐标
    const joints: ComputedJoint[] = computeSkeletonJoints(
      pose.rotations,
      pose.rootOffsetX,
      pose.rootOffsetY
    );

    // 2. 统一坐标转换(全部取整)
    const scale: number = Math.min(this.width, this.height) / 100;
    const offsetX: number = Math.round((this.width - 100 * scale) / 2);
    const offsetY: number = Math.round((this.height - 100 * scale) / 2);

    const boneColor: string = this.getBoneColor();
    const jointColor: string = this.getJointColor();
    const headFill: string = this.getHeadFillColor();
    const headStroke: string = this.getHeadStrokeColor();

    const lineWidth: number = Math.max(3, Math.round(2.2 * scale));
    const jointRadius: number = Math.max(3, Math.round(2.5 * scale));
    const headRadius: number = Math.max(6, Math.round(6 * scale));

    let invalidCount: number = 0;

    // 3. 绘制骨骼连线(沿连线步进绘制小方块,避免 translate/rotate)
    for (let i: number = 0; i < BONE_CONNECTIONS.length; i++) {
      const conn: BoneConnection = BONE_CONNECTIONS[i];
      const parent: ComputedJoint | null = this.findJoint(joints, conn.parent);
      const child: ComputedJoint | null = this.findJoint(joints, conn.child);
      if (parent === null || child === null) {
        continue;
      }
      if (!isFinitePoint(parent.x, parent.y) || !isFinitePoint(child.x, child.y)) {
        invalidCount++;
        continue;
      }
      const px: number = Math.round(offsetX + parent.x * scale);
      const py: number = Math.round(offsetY + parent.y * scale);
      const cx: number = Math.round(offsetX + child.x * scale);
      const cy: number = Math.round(offsetY + child.y * scale);
      this.drawLineWithRects(px, py, cx, cy, lineWidth, boneColor);
    }

    // 4. 绘制关节(整数 fillRect)
    for (let i: number = 0; i < joints.length; i++) {
      const j: ComputedJoint = joints[i];
      if (!isFinitePoint(j.x, j.y)) {
        invalidCount++;
        continue;
      }
      const px: number = Math.round(offsetX + j.x * scale);
      const py: number = Math.round(offsetY + j.y * scale);

      if (j.name === 'Head') {
        // 头部:fillRect 填充 + strokeRect 描边
        ctx.fillStyle = headFill;
        ctx.fillRect(px - headRadius, py - headRadius, headRadius * 2, headRadius * 2);
        ctx.strokeStyle = headStroke;
        ctx.lineWidth = Math.max(1, Math.round(1.5 * scale));
        ctx.strokeRect(px - headRadius, py - headRadius, headRadius * 2, headRadius * 2);
      } else {
        // 关节:fillRect 正方形
        ctx.fillStyle = jointColor;
        ctx.fillRect(px - jointRadius, py - jointRadius, jointRadius * 2, jointRadius * 2);
      }
    }

    return invalidCount;
  }

  /**
   * 沿连线步进绘制多个整数小方块,替代 save/translate/rotate/fillRect。
   *
   * ArkUI Canvas 中 save/translate/rotate 变换不可靠,
   * 改为沿连线在整数坐标上绘制多个 fillRect 小方块组成骨骼。
   *
   * @param x1 起点 X(整数)
   * @param y1 起点 Y(整数)
   * @param x2 终点 X(整数)
   * @param y2 终点 Y(整数)
   * @param thickness 线宽(像素,整数)
   * @param color 填充色
   */
  private drawLineWithRects(
    x1: number, y1: number, x2: number, y2: number,
    thickness: number, color: string
  ): void {
    const ctx: CanvasRenderingContext2D = this.context;
    ctx.fillStyle = color;
    const dx: number = x2 - x1;
    const dy: number = y2 - y1;
    const length: number = Math.sqrt(dx * dx + dy * dy);
    const half: number = Math.floor(thickness / 2);
    if (length < 1) {
      // 极短:画一个小方块
      ctx.fillRect(x1 - half, y1 - half, thickness, thickness);
      return;
    }
    const steps: number = Math.ceil(length);
    for (let s: number = 0; s <= steps; s++) {
      const t: number = s / steps;
      const x: number = Math.round(x1 + dx * t);
      const y: number = Math.round(y1 + dy * t);
      ctx.fillRect(x - half, y - half, thickness, thickness);
    }
  }

  /**
   * 绘制调试信息覆盖层。
   */
  drawDebugOverlay(actionId: string, jointCount: number, invalidCount: number): void {
    if (!ACTION_PREVIEW_DEBUG) {
      return;
    }
    const ctx: CanvasRenderingContext2D = this.context;
    ctx.globalAlpha = 1;

    // 调试信息背景条
    const barHeight: number = 42;
    const barY: number = this.height - barHeight - 2;
    ctx.fillStyle = COLOR_DEBUG_TEXT_BG;
    ctx.fillRect(2, barY, this.width - 4, barHeight);

    // 调试文字(Canvas fillText 在 ArkUI 中可能也不工作,
    // 但文字不是关键验收项,保留调用)
    ctx.fillStyle = COLOR_DEBUG_TEXT;
    ctx.font = '10px sans-serif';
    ctx.textAlign = 'left';
    ctx.textBaseline = 'top';
    const shortId: string = actionId.replace('builtin_', '');
    ctx.fillText(shortId, 6, barY + 3);
    ctx.fillText(this.width.toString() + 'x' + this.height.toString() + 'px', 6, barY + 16);
    ctx.fillText(jointCount.toString() + ' joints, ' + invalidCount.toString() + ' invalid', 6, barY + 29);
  }

  private findJoint(joints: ComputedJoint[], name: string): ComputedJoint | null {
    for (let i: number = 0; i < joints.length; i++) {
      if (joints[i].name === name) {
        return joints[i];
      }
    }
    return null;
  }
}

/** 导出调试开关供外部读取 */
export function isActionPreviewDebug(): boolean {
  return ACTION_PREVIEW_DEBUG;
}
