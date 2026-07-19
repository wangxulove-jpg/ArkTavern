import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window, KeyboardAvoidMode, display } from '@kit.ArkUI';
import { AppServices } from '../services/AppServices';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    // 启动应用服务初始化(异步,不阻塞 onCreate)
    AppServices.initialize(this.context).catch((e: Object): void => {
      hilog.error(DOMAIN, 'testTag', 'AppServices initialize failed: %{public}s', (e as Error).message);
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // 获取系统安全区(状态栏 + 导航栏)高度,存入 AppStorage 供所有页面避让使用。
    // 注意:AvoidArea 返回的是 px,而 ArkUI padding 用 vp,需通过屏幕密度换算。
    try {
      const mainWin: window.Window = windowStage.getMainWindowSync();
      const avoidArea: window.AvoidArea = mainWin.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      // 屏幕密度(pixels per vp),通常 3.0 左右
      const densityPixels: number = display.getDefaultDisplaySync().densityPixels;
      const density: number = densityPixels > 0 ? densityPixels : 3.0;
      // 换算为 vp(向下取整避免 padding 不足)
      const statusBarHeightVp: number = Math.floor(avoidArea.topRect.height / density);
      const navigationBarHeightVp: number = Math.floor(avoidArea.bottomRect.height / density);
      AppStorage.setOrCreate<number>('statusBarHeight', statusBarHeightVp);
      AppStorage.setOrCreate<number>('navigationBarHeight', navigationBarHeightVp);
      hilog.info(DOMAIN, 'testTag',
        'SafeArea px statusBar=%{public}d navBar=%{public}d, density*1000=%{public}d, vp statusBar=%{public}d navBar=%{public}d',
        avoidArea.topRect.height, avoidArea.bottomRect.height,
        Math.round(density * 1000), statusBarHeightVp, navigationBarHeightVp);
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'getWindowAvoidArea failed: %{public}s', (e as Error).message);
      // 兜底默认值(状态栏约 32vp,导航栏约 0vp,鸿蒙 NEXT 手势条不占空间)
      AppStorage.setOrCreate<number>('statusBarHeight', 32);
      AppStorage.setOrCreate<number>('navigationBarHeight', 0);
    }

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      // 键盘避让模式设为 RESIZE:压缩页面高度,顶栏不动,输入框上移到键盘上方
      try {
        windowStage.getMainWindowSync().getUIContext()
          .setKeyboardAvoidMode(KeyboardAvoidMode.RESIZE);
      } catch (e) {
        hilog.error(DOMAIN, 'testTag', 'setKeyboardAvoidMode failed: %{public}s', (e as Error).message);
      }
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}