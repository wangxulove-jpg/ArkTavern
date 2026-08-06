/**
 * WorldSceneLauncherOverlay 场景启动器覆盖层(W-UI-1C 新增)
 *
 * 从地点弹窗触发,显示:
 * - 当前地点 Active 角色(即将支持单选/子集选择,目前全选)
 * - Active Scene 信息(如有)
 * - 继续上次会话(Ended → 新 Scene,不复制旧消息)
 * - 创建新场景
 *
 * 纯 UI 组件,不直接访问 Repository/Service。
 * 数据通过 props 从父组件传入。
 */

import { WorldScene, WorldSceneStatus } from '../../models/world/WorldScene';
import { WorldLocationStatus } from '../../models/world/WorldLocation';
import { WorldStatus } from '../../models/world/World';
import { SheetCharacterUiModel } from '../../viewmodels/world/WorldLocationSceneSheetViewModel';
import { WorldSurfaceCard } from './WorldSurfaceCard';
import { WorldStatusChip } from './WorldStatusChip';
import { WorldPrimaryButton } from './WorldPrimaryButton';
import { WorldSecondaryButton } from './WorldSecondaryButton';
import { CharacterImageView } from '../CharacterImageView';
import { formatWorldTimestamp } from '../../viewmodels/world/WorldUiModels';

export interface LauncherData {
  readonly worldId: string;
  readonly worldStatus: WorldStatus;
  readonly locationId: string;
  readonly locationName: string;
  readonly locationStatus: WorldLocationStatus;
  readonly characters: SheetCharacterUiModel[];
  readonly activeScene: WorldScene | null;
  readonly endedSceneCount: number;
  readonly lastEndedScene: WorldScene | null;
  readonly canStartScene: boolean;
}

@CustomDialog
@Component
export struct WorldSceneLauncherOverlay {
  controller: CustomDialogController;
  @Prop data: LauncherData | null = null;
  private onContinueScene: (locationId: string) => void = (_locationId: string) => {};
  private onCreateScene: (locationId: string) => void = (_locationId: string) => {};
  private onEnterActiveScene: (sceneId: string) => void = (_sceneId: string) => {};

  build(): void {
    Column() {
      if (this.data !== null) {
        this.launcherContent(this.data)
      } else {
        Text('加载中...')
          .fontSize($r('app.float.world_font_body'))
          .fontColor($r('app.color.world_text_tertiary'))
          .padding(24)
      }
    }
    .width('100%')
    .backgroundColor($r('app.color.world_surface_1'))
    .borderRadius({ topLeft: $r('app.float.world_radius_card'), topRight: $r('app.float.world_radius_card') })
    .padding({ left: $r('app.float.world_page_padding'), right: $r('app.float.world_page_padding'), bottom: 24 })
  }

  @Builder
  launcherContent(d: LauncherData): void {
    Column() {
      Text(d.locationName)
        .fontSize($r('app.float.world_font_subtitle'))
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.world_text_primary'))
        .width('100%')
        .margin({ top: 16, bottom: 12 })

      // 参与角色
      WorldSurfaceCard({ elevated: false }) {
        Column() {
          Row() {
            Text('参与角色')
              .fontSize($r('app.float.world_font_caption'))
              .fontColor($r('app.color.world_text_secondary'))
              .layoutWeight(1)
            Text('(即将支持选择)')
              .fontSize($r('app.float.world_font_micro'))
              .fontColor($r('app.color.world_text_tertiary'))
          }
          .width('100%')
          .margin({ bottom: 8 })

          if (d.characters.length === 0) {
            Text('当前地点无角色')
              .fontSize($r('app.float.world_font_caption'))
              .fontColor($r('app.color.world_text_tertiary'))
              .width('100%')
              .textAlign(TextAlign.Center)
              .padding({ top: 8, bottom: 8 })
          } else {
            Scroll() {
              Row() {
                ForEach(d.characters, (c: SheetCharacterUiModel) => {
                  Column() {
                    Stack() {
                      CharacterImageView({
                        imageUri: c.avatarUri,
                        fallbackName: c.displayName,
                        imgWidth: 32,
                        imgHeight: 32,
                        imgBorderRadius: 16,
                        displayMode: 'thumbnail'
                      })
                      if (!c.isActive) {
                        Circle({ width: 8, height: 8 })
                          .fill($r('app.color.world_text_tertiary'))
                          .position({ x: 24, y: 24 })
                      }
                    }
                    .width(32)
                    .height(32)
                    Text(c.displayName)
                      .fontSize(9)
                      .fontColor(c.isActive ? $r('app.color.world_text_primary') : $r('app.color.world_text_tertiary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 2 })
                  }
                  .width(42)
                  .margin({ right: 6 })
                  .alignItems(HorizontalAlign.Center)
                }, (c: SheetCharacterUiModel) => c.instanceId)
              }
            }
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .width('100%')
            .height(48)
          }
        }
        .padding(10)
        .alignItems(HorizontalAlign.Start)
      }

      // Active Scene 信息
      if (d.activeScene !== null) {
        WorldSurfaceCard({ elevated: true }) {
          Column() {
            Row() {
              Text('当前进行中的会话')
                .fontSize($r('app.float.world_font_caption'))
                .fontColor($r('app.color.world_text_secondary'))
                .layoutWeight(1)
              WorldStatusChip({ label: '活动中', isActive: true })
            }
            .width('100%')

            Text('开始: ' + formatWorldTimestamp(d.activeScene.startedAt))
              .fontSize($r('app.float.world_font_micro'))
              .fontColor($r('app.color.world_text_tertiary'))
              .margin({ top: 4 })

            WorldPrimaryButton({
              label: '进入会话',
              onButtonClick: (): void => {
                this.onEnterActiveScene(d.activeScene!.id);
                this.controller.close();
              }
            })
              .margin({ top: 8 })
          }
          .padding(10)
          .alignItems(HorizontalAlign.Start)
        }
        .margin({ top: $r('app.float.world_card_spacing') })
      }

      // 上次结束的会话
      if (d.lastEndedScene !== null) {
        WorldSurfaceCard({ elevated: false }) {
          Column() {
            Row() {
              Text('上次会话')
                .fontSize($r('app.float.world_font_caption'))
                .fontColor($r('app.color.world_text_secondary'))
                .layoutWeight(1)
              WorldStatusChip({ label: '已结束', isActive: false })
            }
            .width('100%')

            Text('结束于: ' + formatWorldTimestamp(
              d.lastEndedScene.endedAt !== undefined ? d.lastEndedScene.endedAt : d.lastEndedScene.startedAt))
              .fontSize($r('app.float.world_font_micro'))
              .fontColor($r('app.color.world_text_tertiary'))
              .margin({ top: 4 })

            Text($r('app.string.world_scene_history_continue_no_copy'))
              .fontSize($r('app.float.world_font_micro'))
              .fontColor($r('app.color.world_text_tertiary'))
              .margin({ top: 2 })

            WorldSecondaryButton({
              label: '基于上次继续新会话',
              isEnabled: d.canStartScene,
              onButtonClick: (): void => {
                this.onContinueScene(d.locationId);
                this.controller.close();
              }
            })
              .margin({ top: 8 })
          }
          .padding(10)
          .alignItems(HorizontalAlign.Start)
        }
        .margin({ top: $r('app.float.world_card_spacing') })
      }

      // 创建全新场景
      if (d.canStartScene) {
        WorldPrimaryButton({
          label: '创建新会话',
          onButtonClick: (): void => {
            this.onCreateScene(d.locationId);
            this.controller.close();
          }
        })
          .margin({ top: $r('app.float.world_card_spacing') })
      }

      if (d.endedSceneCount > 0) {
        Text(d.endedSceneCount.toString() + ' 个历史会话可在历史页查看')
          .fontSize($r('app.float.world_font_micro'))
          .fontColor($r('app.color.world_text_tertiary'))
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
      }

      Text('关闭')
        .fontSize($r('app.float.world_font_caption'))
        .fontColor($r('app.color.world_text_tertiary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 12, bottom: 4 })
        .onClick(() => {
          this.controller.close();
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}