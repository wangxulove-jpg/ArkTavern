/**
 * AvatarLibraryPage Avatar 模型库管理页面
 *
 * T-4.1 阶段 B: 多 Avatar 模型库 UI
 *
 * 功能:
 * - 列出全部已保存 Avatar(显示名 / VRM 标签 / 骨骼摘要 / 导入时间)
 * - 单击 → 设为当前激活
 * - "更多"按钮 → 重命名 / 删除
 * - 顶部"导入新模型"按钮(走 DocumentViewPicker)
 * - VRM 样本快捷导入(Alicia / Seed-san / MToon)
 * - 空列表提示
 * - 当前激活模型高亮显示
 *
 * 不实现:
 * - 模型 3D 预览(由 Character3DPocPage 负责)
 * - 骨骼映射编辑(由 HumanoidMappingPage 负责)
 * - 动作绑定(由 Character3DActionManagerPage 负责)
 */

import { promptAction } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { AppServices } from '../services/AppServices';
import { AvatarLibraryService } from '../services/AvatarLibraryService';
import {
  AvatarLibraryViewModel,
  AvatarListItem
} from '../viewmodels/AvatarLibraryViewModel';
import { AvatarRecord } from '../storage/AvatarLibraryStore';
import { Logger } from '../utils/Logger';

const LOG_TAG: string = 'AvatarLibraryPage';

/** Avatar 列表数据源(LazyForEach 适配) */
class AvatarListDataSource implements IDataSource {
  private items: AvatarListItem[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): AvatarListItem {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const idx: number = this.listeners.indexOf(listener);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  setItems(items: AvatarListItem[]): void {
    this.items = items;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }
}

@Entry
@Component
struct AvatarLibraryPage {
  @State private vm: AvatarLibraryViewModel = new AvatarLibraryViewModel();
  @State private items: AvatarListItem[] = [];
  @State private activeAvatarId: string = '';
  @State private isLoading: boolean = false;
  @State private errorMessage: string = '';
  @State private isImporting: boolean = false;

  /** 重命名弹窗状态 */
  @State private renameTarget: AvatarRecord | null = null;
  @State private renameInput: string = '';

  /** 删除确认弹窗状态 */
  @State private deleteTarget: AvatarRecord | null = null;

  private dataSource: AvatarListDataSource = new AvatarListDataSource();

  /** 顶部状态栏避让高度 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航栏避让高度 */
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;

  async aboutToAppear(): Promise<void> {
    Logger.info(LOG_TAG, 'aboutToAppear');
    try {
      await AppServices.whenReady();
      const service: AvatarLibraryService | null = AppServices.getAvatarLibraryService();
      if (service === null) {
        this.errorMessage = 'AvatarLibraryService 不可用';
        return;
      }
      this.vm.setService(service);
      this.bindVmCallbacks();
      await this.vm.initialize();
    } catch (e) {
      Logger.error(LOG_TAG, 'aboutToAppear failed: ' + (e as Error)?.message);
      this.errorMessage = '初始化失败: ' + (e as Error)?.message;
    }
  }

  private bindVmCallbacks(): void {
    this.vm.onListChanged = (items: AvatarListItem[]): void => {
      this.items = items;
      this.dataSource.setItems(items);
    };
    this.vm.onActiveChanged = (activeId: string): void => {
      this.activeAvatarId = activeId;
    };
    this.vm.onLoadingChanged = (loading: boolean): void => {
      this.isLoading = loading;
    };
    this.vm.onError = (message: string): void => {
      this.errorMessage = message;
      promptAction.showToast({ message: message, duration: 2000 });
    };
  }

  build(): void {
    NavDestination() {
      Column() {
        this.buildHeader();
        this.buildActionButtons();
        if (this.errorMessage.length > 0) {
          Text(this.errorMessage)
            .fontSize(12)
            .fontColor($r('app.color.app_danger'))
            .width('100%')
            .padding({ left: 16, right: 16, top: 6, bottom: 6 })
            .backgroundColor($r('app.color.app_surface_2'));
        }
        if (this.isLoading && this.items.length === 0) {
          this.buildLoading();
        } else if (this.items.length === 0) {
          this.buildEmpty();
        } else {
          this.buildList();
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.page_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // 弹层
      if (this.renameTarget !== null) {
        this.buildRenameDialog();
      }
      if (this.deleteTarget !== null) {
        this.buildDeleteConfirmDialog();
      }
    }
    .hideTitleBar(true)
    .mode(NavDestinationMode.STANDARD)
  }

  @Builder
  buildHeader(): void {
    Row() {
      Text('Avatar 模型库')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .layoutWeight(1)
      if (this.activeAvatarId.length > 0) {
        Text('当前激活已设置')
          .fontSize(11)
          .fontColor($r('app.color.app_text_tertiary'))
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12 + this.statusBarHeight, bottom: 8 })
    .backgroundColor($r('app.color.app_surface_1'))
  }

  @Builder
  buildActionButtons(): void {
    Column() {
      // 主操作:导入新模型
      Button('导入新模型')
        .fontSize(13)
        .backgroundColor($r('app.color.app_accent'))
        .fontColor(Color.White)
        .height(36)
        .width('100%')
        .enabled(!this.isImporting && !this.isLoading)
        .key('avatarLibrary.import')
        .onClick(() => {
          this.onClickImportFromPicker();
        })

      // VRM 样本快捷导入
      Row() {
        Text('VRM 样本:')
          .fontSize(11)
          .fontColor($r('app.color.app_text_tertiary'))
        Button('Alicia(0.x)')
          .fontSize(10)
          .backgroundColor('#6f42c1')
          .fontColor(Color.White)
          .height(28)
          .layoutWeight(1)
          .margin({ left: 4 })
          .enabled(!this.isImporting && !this.isLoading)
          .onClick(() => {
            this.onClickImportVrmSample('vrm_samples/vrm0_alicia_solid_0.51.vrm', 'Alicia(VRM0.x)');
          })
        Button('Seed-san(1.0)')
          .fontSize(10)
          .backgroundColor('#6f42c1')
          .fontColor(Color.White)
          .height(28)
          .layoutWeight(1)
          .margin({ left: 4 })
          .enabled(!this.isImporting && !this.isLoading)
          .onClick(() => {
            this.onClickImportVrmSample('vrm_samples/vrm1_seed_san.vrm', 'SeedSan(VRM1.0)');
          })
        Button('MToon(1.0)')
          .fontSize(10)
          .backgroundColor('#6f42c1')
          .fontColor(Color.White)
          .height(28)
          .layoutWeight(1)
          .margin({ left: 4 })
          .enabled(!this.isImporting && !this.isLoading)
          .onClick(() => {
            this.onClickImportVrmSample('vrm_samples/vrm1_mtoon_uv_animation.vrm', 'MToon(VRM1.0)');
          })
      }
      .width('100%')
      .margin({ top: 8 })

      // 清空全部(开发测试/重置)
      if (this.items.length > 0) {
        Button('清空全部')
          .fontSize(11)
          .backgroundColor($r('app.color.app_danger'))
          .fontColor(Color.White)
          .height(28)
          .width('100%')
          .margin({ top: 6 })
          .enabled(!this.isImporting && !this.isLoading)
          .key('avatarLibrary.clearAll')
          .onClick(() => {
            this.onClickClearAll();
          })
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .backgroundColor($r('app.color.app_surface_1'))
  }

  @Builder
  buildLoading(): void {
    Column() {
      LoadingProgress()
        .width(40)
        .height(40)
        .color($r('app.color.app_accent'))
      Text('加载中...')
        .fontSize(12)
        .fontColor($r('app.color.app_text_secondary'))
        .margin({ top: 8 })
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  buildEmpty(): void {
    Column() {
      Text('🏪')
        .fontSize(48)
      Text('模型库为空')
        .fontSize(14)
        .fontColor($r('app.color.app_text_secondary'))
        .margin({ top: 8 })
      Text('点击上方"导入新模型"按钮,或导入 VRM 样本开始')
        .fontSize(11)
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ top: 4 })
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .padding({ left: 24, right: 24 })
  }

  @Builder
  buildList(): void {
    List({ space: 8 }) {
      ForEach(this.items, (item: AvatarListItem, index: number) => {
        ListItem() {
          this.buildAvatarCard(item)
        }
      }, (item: AvatarListItem) => item.record.avatarId)
    }
    .width('100%')
    .layoutWeight(1)
    .padding({ left: 12, right: 12, top: 4, bottom: 12 })
    .scrollBar(BarState.Auto)
  }

  @Builder
  buildAvatarCard(item: AvatarListItem): void {
    Row() {
      // 左侧:VRM 标签 + 激活标记
      Column() {
        Text(item.vrmLabel)
          .fontSize(10)
          .fontColor(item.record.isVrm ? '#6f42c1' : $r('app.color.app_text_tertiary'))
          .fontWeight(FontWeight.Medium)
        if (item.isActive) {
          Text('●激活')
            .fontSize(9)
            .fontColor($r('app.color.app_accent'))
            .margin({ top: 4 })
        }
      }
      .width(56)
      .alignItems(HorizontalAlign.Center)

      // 中间:显示名 + 骨骼摘要 + 导入时间
      Column() {
        Text(item.record.displayName)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(item.boneSummary)
          .fontSize(11)
          .fontColor($r('app.color.app_text_secondary'))
          .margin({ top: 2 })
          .width('100%')
        Text(item.importedAtLabel)
          .fontSize(10)
          .fontColor($r('app.color.app_text_tertiary'))
          .margin({ top: 2 })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 8 })

      // 右侧:操作按钮
      Row() {
        if (!item.isActive) {
          Button('设为当前')
            .fontSize(11)
            .backgroundColor($r('app.color.app_accent'))
            .fontColor(Color.White)
            .height(28)
            .padding({ left: 8, right: 8 })
            .enabled(!this.isLoading)
            .key('avatarLibrary.card.' + item.record.avatarId + '.setActive')
            .onClick(() => {
              this.onClickSetActive(item.record.avatarId);
            })
        }
        // 更多菜单(重命名/删除)
        Button('⋯')
          .fontSize(14)
          .backgroundColor($r('app.color.app_surface_2'))
          .fontColor($r('app.color.app_text_secondary'))
          .height(28)
          .width(28)
          .padding(0)
          .margin({ left: 4 })
          .key('avatarLibrary.card.' + item.record.avatarId + '.more')
          .onClick(() => {
            this.onClickMoreMenu(item.record);
          })
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(12)
    .key('avatarLibrary.card.' + item.record.avatarId)
    .backgroundColor($r('app.color.app_surface_1'))
    .borderRadius(8)
    .border({
      width: item.isActive ? 1.5 : 0,
      color: item.isActive ? $r('app.color.app_accent') : Color.Transparent
    })
  }

  @Builder
  buildRenameDialog(): void {
    Column() {
      Column() {
        Text('重命名 Avatar')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .margin({ top: 16, bottom: 12 })

        TextInput({ text: this.renameInput, placeholder: '输入新名称' })
          .fontSize(14)
          .width('90%')
          .height(40)
          .margin({ bottom: 16 })
          .onChange((value: string) => {
            this.renameInput = value;
          })

        Row() {
          Button('取消')
            .fontSize(13)
            .backgroundColor($r('app.color.app_surface_2'))
            .fontColor($r('app.color.app_text_secondary'))
            .height(36)
            .layoutWeight(1)
            .key('avatarLibrary.rename.cancel')
            .onClick(() => {
              this.renameTarget = null;
              this.renameInput = '';
            })
          Button('确定')
            .fontSize(13)
            .backgroundColor($r('app.color.app_accent'))
            .fontColor(Color.White)
            .height(36)
            .layoutWeight(1)
            .margin({ left: 8 })
            .key('avatarLibrary.rename.confirm')
            .onClick(() => {
              this.onClickConfirmRename();
            })
        }
        .width('90%')
        .margin({ bottom: 16 })
      }
      .width('85%')
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .position({ x: 0, y: 0 })
    .backgroundColor('rgba(0,0,0,0.6)')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  buildDeleteConfirmDialog(): void {
    Column() {
      Column() {
        Text('确认删除')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.app_text_primary'))
          .margin({ top: 16, bottom: 8 })
        Text('将同时删除模型文件和元数据,此操作不可撤销')
          .fontSize(12)
          .fontColor($r('app.color.app_text_secondary'))
          .textAlign(TextAlign.Center)
          .margin({ bottom: 4 })
        if (this.deleteTarget !== null) {
          Text('名称: ' + this.deleteTarget.displayName)
            .fontSize(13)
            .fontColor($r('app.color.app_text_primary'))
            .margin({ bottom: 16 })
        }

        Row() {
          Button('取消')
            .fontSize(13)
            .backgroundColor($r('app.color.app_surface_2'))
            .fontColor($r('app.color.app_text_secondary'))
            .height(36)
            .layoutWeight(1)
            .key('avatarLibrary.delete.cancel')
            .onClick(() => {
              this.deleteTarget = null;
            })
          Button('删除')
            .fontSize(13)
            .backgroundColor($r('app.color.app_danger'))
            .fontColor(Color.White)
            .height(36)
            .layoutWeight(1)
            .margin({ left: 8 })
            .key('avatarLibrary.delete.confirm')
            .onClick(() => {
              this.onClickConfirmDelete();
            })
        }
        .width('90%')
        .margin({ bottom: 16 })
      }
      .width('85%')
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .position({ x: 0, y: 0 })
    .backgroundColor('rgba(0,0,0,0.6)')
    .justifyContent(FlexAlign.Center)
  }

  // ========== 事件处理 ==========

  private async onClickImportFromPicker(): Promise<void> {
    if (this.isImporting) {
      return;
    }
    this.isImporting = true;
    this.errorMessage = '';
    try {
      const documentPicker = new picker.DocumentViewPicker();
      const options = new picker.DocumentSelectOptions();
      options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['.glb', '.gltf', '.vrm'];
      const uris: string[] = await documentPicker.select(options);
      if (uris.length === 0) {
        return;
      }
      const sourceUri: string = uris[0];
      // 从 URI 提取显示名(简化:取最后一段路径)
      const displayName: string = this.extractDisplayNameFromUri(sourceUri);
      promptAction.showToast({ message: '正在导入 ' + displayName + '…', duration: 1500 });
      const result = await this.vm.importAvatar(sourceUri, displayName);
      if (result !== null) {
        promptAction.showToast({
          message: '已入库: ' + result.record.displayName
            + ' (骨骼 ' + result.record.validHumanBoneCount
            + '/' + result.record.declaredHumanBoneCount + ')',
          duration: 2500
        });
      }
    } catch (e) {
      const msg: string = (e as Error)?.message ?? '导入失败';
      this.errorMessage = msg;
      promptAction.showToast({ message: '导入失败: ' + msg, duration: 2000 });
    } finally {
      this.isImporting = false;
    }
  }

  private async onClickImportVrmSample(rawfilePath: string, displayName: string): Promise<void> {
    if (this.isImporting) {
      return;
    }
    this.isImporting = true;
    this.errorMessage = '';
    try {
      promptAction.showToast({ message: '正在导入 ' + displayName + '…', duration: 1500 });
      const result = await this.vm.importAvatarFromRawfile(rawfilePath, displayName);
      if (result !== null) {
        promptAction.showToast({
          message: '已入库: ' + result.record.displayName
            + ' (骨骼 ' + result.record.validHumanBoneCount
            + '/' + result.record.declaredHumanBoneCount + ')',
          duration: 2500
        });
      }
    } catch (e) {
      const msg: string = (e as Error)?.message ?? '导入失败';
      this.errorMessage = msg;
      promptAction.showToast({ message: '导入失败: ' + msg, duration: 2000 });
    } finally {
      this.isImporting = false;
    }
  }

  private async onClickSetActive(avatarId: string): Promise<void> {
    const ok: boolean = await this.vm.setActive(avatarId);
    if (ok) {
      promptAction.showToast({ message: '已设为当前激活', duration: 1500 });
    }
  }

  private onClickMoreMenu(record: AvatarRecord): void {
    // 简化:用 ActionSheet 风格的二选一(重命名 / 删除)
    // ArkUI 没有 ActionSheet 直接 API,这里用 promptAction.showActionMenu
    promptAction.showActionMenu({
      title: record.displayName,
      buttons: [
        { text: '重命名', color: '#007aff' },
        { text: '删除', color: '#ff3b30' }
      ]
    }).then((result: promptAction.ActionMenuSuccessResponse) => {
      if (result.index === 0) {
        this.renameTarget = record;
        this.renameInput = record.displayName;
      } else if (result.index === 1) {
        this.deleteTarget = record;
      }
    }).catch((_e: Error) => {
      // 用户取消,忽略
    });
  }

  private async onClickConfirmRename(): Promise<void> {
    if (this.renameTarget === null) {
      return;
    }
    const avatarId: string = this.renameTarget.avatarId;
    const newName: string = this.renameInput;
    this.renameTarget = null;
    this.renameInput = '';
    const ok: boolean = await this.vm.rename(avatarId, newName);
    if (ok) {
      promptAction.showToast({ message: '已重命名', duration: 1500 });
    }
  }

  private async onClickConfirmDelete(): Promise<void> {
    if (this.deleteTarget === null) {
      return;
    }
    const avatarId: string = this.deleteTarget.avatarId;
    this.deleteTarget = null;
    const ok: boolean = await this.vm.delete(avatarId);
    if (ok) {
      promptAction.showToast({ message: '已删除', duration: 1500 });
    }
  }

  private async onClickClearAll(): Promise<void> {
    try {
      const ok: boolean = await this.vm.clearAll();
      if (ok) {
        promptAction.showToast({ message: '已清空全部模型', duration: 1500 });
      }
    } catch (e) {
      promptAction.showToast({ message: '清空失败: ' + (e as Error)?.message, duration: 2000 });
    }
  }

  private extractDisplayNameFromUri(uri: string): string {
    let path: string = uri;
    const queryIdx: number = path.indexOf('?');
    if (queryIdx >= 0) {
      path = path.substring(0, queryIdx);
    }
    const lastSlash: number = path.lastIndexOf('/');
    const filename: string = lastSlash >= 0 ? path.substring(lastSlash + 1) : path;
    const lastDot: number = filename.lastIndexOf('.');
    if (lastDot <= 0) {
      return filename.length > 0 ? filename : '未知模型';
    }
    return filename.substring(0, lastDot);
  }
}
