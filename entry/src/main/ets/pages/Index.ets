/**
 * Index 方舟酒馆入口(UI-1 HDS Immersive Bottom Tabs App Shell)
 *
 * UI-1 重构后,Index 仅作为 @Entry 入口,真正的内容由 AppShell 提供。
 *
 * AppShell 内部:
 * - 顶层 Navigation(pathStack)包裹 HdsTabs
 * - HdsTabs 提供四个一级 Tab:角色卡 / 对话记录 / 市场 / 设置
 * - barFloatingStyle + systemMaterialEffect 启用沉浸光感材质
 * - 二级页面(ChatPage / CharacterListPage 等)通过 NavPathStack 推入,
 *   自动覆盖 HdsTabs,实现"进入二级页面隐藏底部页签"
 *
 * 不修改:
 * - 业务 Service / Repository / 数据库
 * - NavPathStack 路由命名(由 AppShell 内 pageMap 维护)
 * - 其他二级页面
 */

import { AppShell } from './AppShell';
import { AppServices } from '../services/AppServices';

@Entry
@Component
struct Index {
  async aboutToAppear(): Promise<void> {
    try {
      // 确保全局 Service 已就绪(数据库、Preferences 等)
      await AppServices.whenReady();
    } catch (e) {
      // AppShell 内部各 RootView 会处理自己的初始化错误,
      // 此处仅确保 AppServices 启动,失败也不阻塞 UI 外壳渲染
    }
  }

  build() {
    Column() {
      AppShell()
    }
    .width('100%')
    .height('100%')
  }
}
