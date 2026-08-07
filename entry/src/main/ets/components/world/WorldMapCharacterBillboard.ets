/**
 * WorldMapCharacterBillboard 角色头像布告板(W1D)
 *
 * 沉浸式地图中地点节点旁的角色头像布告板:
 * - 显示最多 BILLBOARD_MAX_VISIBLE 个头像,按偏移排列
 * - 超出部分显示 "+N"
 * - 头像带活跃/停用状态指示
 *
 * 纯 UI 组件,不依赖 Repository / Service / AppServices / 数据库。
 */

import { CharacterImageView } from '../CharacterImageView';

export interface BillboardCharacterSlotData {
  readonly instanceId: string;
  readonly displayName: string;
  readonly avatarUri: string;
  readonly fallbackName: string;
  readonly isActive: boolean;
  readonly dx: number;
  readonly dy: number;
}

@Component
export struct WorldMapCharacterBillboard {
  @Prop slots: BillboardCharacterSlotData[] = [];
  @Prop overflowCount: number = 0;
  onCharacterTap: (instanceId: string) => void = (_instanceId: string): void => {};
  onOverflowTap: () => void = (): void => {};

  build(): void {
    Stack() {
      ForEach(this.slots, (slot: BillboardCharacterSlotData) => {
        Stack({ alignContent: Alignment.Bottom }) {
          CharacterImageView({
            imageUri: slot.avatarUri,
            fallbackName: slot.fallbackName,
            imgWidth: 22,
            imgHeight: 22,
            imgBorderRadius: 11,
            displayMode: 'thumbnail',
            objectFit: ImageFit.Cover
          })
          if (!slot.isActive) {
            Circle({ width: 6, height: 6 })
              .fill($r('app.color.world_text_tertiary'))
              .position({ x: 14, y: 14 })
          }
        }
        .width(22)
        .height(22)
        .position({ x: slot.dx, y: slot.dy })
        .borderWidth(1.5)
        .borderColor($r('app.color.world_map_bg'))
        .borderRadius(11)
        .onClick(() => {
          this.onCharacterTap(slot.instanceId);
        })
      }, (slot: BillboardCharacterSlotData) => slot.instanceId)

      if (this.overflowCount > 0) {
        Text('+' + this.overflowCount.toString())
          .fontSize(9)
          .fontColor($r('app.color.world_text_secondary'))
          .backgroundColor($r('app.color.world_surface_2'))
          .borderRadius(8)
          .width(16)
          .height(16)
          .textAlign(TextAlign.Center)
          .position({ x: this.computeOverflowX(), y: 0 })
          .onClick(() => {
            this.onOverflowTap();
          })
      }
    }
    .width(this.computeStackWidth())
    .height(this.computeStackHeight())
  }

  private computeOverflowX(): number {
    if (this.slots.length === 0) {
      return 0;
    }
    let maxX: number = 0;
    for (let i: number = 0; i < this.slots.length; i++) {
      const right: number = this.slots[i].dx + 22;
      if (right > maxX) {
        maxX = right;
      }
    }
    return maxX + 2;
  }

  private computeStackWidth(): number {
    if (this.slots.length === 0) {
      return 0;
    }
    let maxX: number = 0;
    for (let i: number = 0; i < this.slots.length; i++) {
      const right: number = Math.abs(this.slots[i].dx) + 22;
      if (right > maxX) {
        maxX = right;
      }
    }
    if (this.overflowCount > 0) {
      maxX = maxX + 20;
    }
    return maxX;
  }

  private computeStackHeight(): number {
    if (this.slots.length === 0) {
      return 0;
    }
    let maxY: number = 0;
    for (let i: number = 0; i < this.slots.length; i++) {
      const bottom: number = Math.abs(this.slots[i].dy) + 22;
      if (bottom > maxY) {
        maxY = bottom;
      }
    }
    return maxY;
  }
}
