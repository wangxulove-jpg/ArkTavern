/**
 * ChatMoreMenuSheet 聊天页顶部更多菜单(底部弹出)
 *
 * 把模型、预设、分支、会话等次要入口收敛到这里,
 * 让顶部栏只保留:返回 + 角色名 + 更多按钮。
 *
 * 菜单项:
 * - 模型信息(只读显示)+ 前往模型设置
 * - 预设信息(只读显示)+ 前往预设列表
 * - 分支状态(只读显示)+ 查看分支图
 * - 会话列表
 * - 重新生成(底部 canRegenerate 时)
 * - 清空对话(危险操作,二次确认)
 *
 * T-3D.5A 新增:
 * - 3D 角色模型开关(读写同一 Chat3DDisplaySettings)
 * - 模型显示比例调节(Slider + 自动适配)
 *
 * 复用 ChatViewModel 数据,不在组件内做业务操作。
 */

@Component
export struct ChatMoreMenuSheet {
  /** 是否显示 */
  visible: boolean = false;
  /** 当前角色名 */
  characterName: string = '';
  /** 当前模型名 */
  modelName: string = '';
  /** 当前预设名(空表示未启用) */
  presetName: string = '';
  /** 是否有可用模型 */
  hasModel: boolean = false;
  /** 分支状态文本 */
  branchStatusText: string = '';
  /** 是否可重新生成 */
  canRegenerate: boolean = false;
  /** 是否生成中 */
  isGenerating: boolean = false;
  /** 是否忙碌 */
  busy: boolean = false;
  /** 关闭回调 */
  onClose: () => void = () => {};
  /** 前往模型设置 */
  onGoModelSettings: () => void = () => {};
  /** 前往预设列表 */
  onGoPresetList: () => void = () => {};
  /** 查看分支图 */
  onGoBranchMap: () => void = () => {};
  /** 打开会话列表 */
  onOpenSessionList: () => void = () => {};
  /** 前往聊天背景设置 */
  onGoChatBackground: () => void = () => {};
  /** 前往对话记忆管理 */
  onGoMemory: () => void = () => {};
  /** 前往上下文管理 */
  onGoContextBudget: () => void = () => {};
  /** v9: 打开本对话称呼覆盖编辑(回调决定具体 UI 形式) */
  onEditUserNameOverride: () => void = () => {};
  /** 重新生成 */
  onRegenerate: () => void = () => {};
  /** 清空对话 */
  onClearChat: () => void = () => {};

  /** v9: 当前对话级用户称呼覆盖(空表示跟随角色或全局) */
  @Prop userNameOverride: string = '';
  /** v9: 当前生效的用户称呼(用于在菜单展示) */
  @Prop resolvedUserName: string = '';

  /** T-3D.5A: 是否为单人角色聊天(决定是否显示 3D 开关) */
  @Prop isSingleCharacterChat: boolean = false;
  /** T-3D.5A: 3D 显示开关当前值 */
  @Prop chat3DEnabled: boolean = false;
  /** T-3D.5A: 当前模型显示比例(用于 Slider 初始值) */
  @Prop modelScale: number = 1.0;
  /** T-3D.5A: 是否有外部模型(决定是否显示 scale 调节) */
  @Prop hasExternalModel: boolean = false;
  /** T-3D.5B: 3D 区域占比(0.25 ~ 0.65) */
  @Prop panelRatio: number = 0.40;
  /** T-3D.5B: 旋转灵敏度(0.2 ~ 2.0) */
  @Prop rotationSensitivity: number = 1.0;
  /** T-3D.5A: 切换 3D 开关 */
  onToggleChat3D: (enabled: boolean) => void = () => {};
  /** T-3D.5A: scale 变化(实时预览,不落盘) */
  onScaleChange: (scale: number) => void = () => {};
  /** T-3D.5A: scale 确认(落盘) */
  onScaleConfirm: () => void = () => {};
  /** T-3D.5A: 自动适配(恢复当前模型 autoFit) */
  onAutoFit: () => void = () => {};
  /** T-3D.5B: panelRatio 变化(实时预览) */
  onPanelRatioChange: (ratio: number) => void = () => {};
  /** T-3D.5B: panelRatio 确认(落盘) */
  onPanelRatioConfirm: () => void = () => {};
  /** T-3D.5B: 旋转灵敏度变化(实时预览) */
  onSensitivityChange: (sensitivity: number) => void = () => {};
  /** T-3D.5B: 旋转灵敏度确认(落盘) */
  onSensitivityConfirm: () => void = () => {};

  build() {
    if (this.visible) {
      Stack() {
        Column() {
          Blank().layoutWeight(1)
          Column() {
            this.sheetContent()
          }
          .width('100%')
          .backgroundColor($r('app.color.app_surface_1'))
          .borderRadius({
            topLeft: 16, topRight: 16,
            bottomLeft: 0, bottomRight: 0
          })
          .padding({ top: 8, bottom: 24 })
        }
        .width('100%')
        .height('100%')
      }
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.5)')
      .onClick(() => {
        this.onClose();
      })
      .transition(TransitionEffect.OPACITY)
    }
  }

  @Builder
  sheetContent() {
    Column() {
      Text('对话设置')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ top: 12, bottom: 8, left: 16, right: 16 })

      // 模型信息
      this.infoRow('模型', this.modelName.length > 0 ? this.modelName : '未配置', true, (): void => {
        this.onGoModelSettings();
      })

      // 预设
      this.infoRow('预设', this.presetName.length > 0 ? this.presetName : '未启用', true, (): void => {
        this.onGoPresetList();
      })

      // 分支
      if (this.branchStatusText.length > 0) {
        this.infoRow('分支', this.branchStatusText, !this.busy, (): void => {
          if (this.busy) {
            return;
          }
          this.onGoBranchMap();
        })
      }

      Divider().color($r('app.color.app_divider')).margin({ top: 8, bottom: 8 })

      // T-3D.5A: 3D 角色模型开关(仅单人角色聊天显示)
      if (this.isSingleCharacterChat) {
        this.toggle3DRow()
      }

      // T-3D.5A: 模型显示比例调节(3D 开启 + 有外部模型时显示)
      if (this.isSingleCharacterChat && this.chat3DEnabled && this.hasExternalModel) {
        this.scaleSliderRow()
      }

      // T-3D.5B: 3D 画面占比调节(3D 开启时显示)
      if (this.isSingleCharacterChat && this.chat3DEnabled) {
        this.panelRatioSliderRow()
      }

      // T-3D.5B: 旋转灵敏度调节(3D 开启时显示)
      if (this.isSingleCharacterChat && this.chat3DEnabled) {
        this.sensitivitySliderRow()
      }

      Divider().color($r('app.color.app_divider')).margin({ top: 8, bottom: 8 })

      // 会话列表
      this.menuRow('会话列表', false, false, (): void => {
        this.onOpenSessionList();
      })

      // 对话设置(背景 + 思考强度)
      this.menuRow('对话设置', this.busy, false, (): void => {
        if (this.busy) {
          return;
        }
        this.onGoChatBackground();
      })

      // 对话记忆(长期记忆摘要管理)
      this.menuRow('对话记忆', this.busy, false, (): void => {
        if (this.busy) {
          return;
        }
        this.onGoMemory();
      })

      // 上下文管理(预算设置 + 占用查看)
      this.menuRow('上下文管理', this.busy, false, (): void => {
        if (this.busy) {
          return;
        }
        this.onGoContextBudget();
      })

      // 本对话称呼(v9:对话级用户称呼覆盖)
      this.infoRow(
        '本对话称呼',
        this.resolvedUserName.length > 0 ? this.resolvedUserName : 'User',
        !this.busy,
        (): void => {
          if (this.busy) {
            return;
          }
          this.onEditUserNameOverride();
        }
      )

      // 重新生成
      if (this.canRegenerate) {
        this.menuRow('重新生成', this.isGenerating, false, (): void => {
          if (this.isGenerating) {
            return;
          }
          this.onRegenerate();
        })
      }

      // 清空对话
      this.menuRow('清空对话', this.busy, true, (): void => {
        this.onClearChat();
      })
    }
    .width('100%')
  }

  /**
   * T-3D.5A: 3D 角色模型开关行。
   * 读写同一 Chat3DDisplaySettings,与全局设置页同步。
   */
  @Builder
  toggle3DRow() {
    Row() {
      Text('3D 角色模型')
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_primary'))
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.chat3DEnabled })
        .onChange((isOn: boolean) => {
          this.onToggleChat3D(isOn);
        })
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * T-3D.5A: 模型显示比例调节行。
   * Slider 拖动时实时预览(不落盘),拖动结束后落盘。
   * 提供"自动适配"按钮,恢复当前模型 autoFit 计算。
   */
  @Builder
  scaleSliderRow() {
    Column() {
      Row() {
        Text('模型显示比例')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .layoutWeight(1)
        Text(this.modelScale.toFixed(2))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
        Button('自动适配')
          .fontSize($r('app.float.app_font_caption'))
          .backgroundColor($r('app.color.app_surface_2'))
          .fontColor($r('app.color.app_text_secondary'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(28)
          .padding({ left: 12, right: 12 })
          .margin({ left: 8 })
          .onClick(() => {
            this.onAutoFit();
          })
      }
      .width('100%')
      .height(40)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      Row() {
        Slider({
          value: this.modelScale,
          min: 0.25,
          max: 8.0,
          step: 0.1
        })
          .layoutWeight(1)
          .blockColor($r('app.color.app_accent'))
          .trackColor($r('app.color.app_surface_2'))
          .selectedColor($r('app.color.app_accent'))
          .onChange((value: number, mode: SliderChangeMode) => {
            // 实时预览(Moving/Click 模式)
            if (mode === SliderChangeMode.Moving || mode === SliderChangeMode.Click) {
              this.onScaleChange(value);
            }
            // 拖动结束落盘(End/Click 模式)
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.onScaleConfirm();
            }
          })
      }
      .width('100%')
      .height(40)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  /**
   * T-3D.5B: 3D 画面占比调节行。
   * 控制聊天页中 3D 区域占可用高度的比例(0.25 ~ 0.65)。
   * Slider 拖动时实时预览,拖动结束后落盘。
   */
  @Builder
  panelRatioSliderRow() {
    Column() {
      Row() {
        Text('3D 画面占比')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .layoutWeight(1)
        Text(Math.round(this.panelRatio * 100) + '%')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
      }
      .width('100%')
      .height(40)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      Row() {
        Slider({
          value: this.panelRatio,
          min: 0.25,
          max: 0.65,
          step: 0.05
        })
          .layoutWeight(1)
          .blockColor($r('app.color.app_accent'))
          .trackColor($r('app.color.app_surface_2'))
          .selectedColor($r('app.color.app_accent'))
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.Moving || mode === SliderChangeMode.Click) {
              this.onPanelRatioChange(value);
            }
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.onPanelRatioConfirm();
            }
          })
      }
      .width('100%')
      .height(40)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  /**
   * T-3D.5B: 旋转灵敏度调节行。
   * 控制单指拖动旋转模型时的灵敏度(0.2 ~ 2.0,1.0 = 标准)。
   * Slider 拖动时实时生效,拖动结束后落盘。
   */
  @Builder
  sensitivitySliderRow() {
    Column() {
      Row() {
        Text('旋转灵敏度')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .layoutWeight(1)
        Text(this.rotationSensitivity.toFixed(2))
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_text_secondary'))
      }
      .width('100%')
      .height(40)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      Row() {
        Slider({
          value: this.rotationSensitivity,
          min: 0.2,
          max: 2.0,
          step: 0.05
        })
          .layoutWeight(1)
          .blockColor($r('app.color.app_accent'))
          .trackColor($r('app.color.app_surface_2'))
          .selectedColor($r('app.color.app_accent'))
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.Moving || mode === SliderChangeMode.Click) {
              this.onSensitivityChange(value);
            }
            if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
              this.onSensitivityConfirm();
            }
          })
      }
      .width('100%')
      .height(40)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
  }

  @Builder
  infoRow(label: string, value: string, enabled: boolean, onClick: () => void) {
    Row() {
      Text(label)
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_secondary'))
        .width(56)
      Text(value)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(enabled
          ? $r('app.color.app_text_primary')
          : $r('app.color.app_text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text('›')
        .fontSize(20)
        .fontColor($r('app.color.app_text_tertiary'))
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (!enabled) {
        return;
      }
      onClick();
      this.onClose();
    })
  }

  @Builder
  menuRow(label: string, disabled: boolean, isDestructive: boolean, onClick: () => void) {
    Row() {
      Text(label)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(isDestructive
          ? (disabled ? $r('app.color.app_text_tertiary') : $r('app.color.app_danger'))
          : (disabled ? $r('app.color.app_text_tertiary') : $r('app.color.app_text_primary')))
        .layoutWeight(1)
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 16 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      if (disabled) {
        return;
      }
      onClick();
    })
  }
}
