/**
 * GroupAvatarStack 群聊头像堆叠
 *
 * G-UI-1 预览组件:在群聊卡片上展示 2~4 个重叠头像。
 *
 * 纯 UI,复用 CharacterImageView。
 * 不依赖 Service / Repository / 数据库。
 */

import { CharacterImageView } from '../CharacterImageView';

/** 头像堆叠项 */
export interface GroupAvatarStackItem {
  readonly name: string;
  readonly avatarUri: string;
}

@Component
export struct GroupAvatarStack {
  /** 头像项列表(最多展示 4 个) */
  items: GroupAvatarStackItem[] = [];
  /** 单个头像尺寸 */
  avatarSize: number = 32;
  /** 重叠偏移(占头像尺寸的比例) */
  overlapRatio: number = 0.4;

  build(): void {
    Row() {
      ForEach(this.items.slice(0, 4), (item: GroupAvatarStackItem, index: number) => {
        Stack() {
          CharacterImageView({
            imageUri: item.avatarUri,
            fallbackName: item.name,
            imgWidth: this.avatarSize,
            imgHeight: this.avatarSize,
            imgBorderRadius: this.avatarSize / 2,
            displayMode: 'thumbnail',
            objectFit: ImageFit.Cover
          })
        }
        .width(this.avatarSize)
        .height(this.avatarSize)
        .margin({ left: index === 0 ? 0 : -this.avatarSize * this.overlapRatio })
        .border({ width: 2, color: $r('app.color.app_surface_1') })
      }, (item: GroupAvatarStackItem, index: number) => String(index) + '_' + item.name)
    }
    .alignItems(VerticalAlign.Center)
  }
}
