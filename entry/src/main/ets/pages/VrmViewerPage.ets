/**
 * VrmViewerPage VRM 查看器页面(Phase 1D-2A: 缓存模型向 ArkWeb 暴露与传输协议)
 *
 * 实现路线:ArkUI 原生外壳 + ArkWeb 加载本地 Viewer 页面 + Figure 源码适配。
 * 原因:ArkGraphics3D 当前缺少 SkinnedMesh / Skeleton / VRM Extension 等 BLOCKING 能力,
 *       见 docs/vrm/ARKGRAPHICS3D_API_MAPPING.md。
 *
 * Phase 1D-2A 范围:
 * - 接入 ArkWebModelResourceProvider(管理缓存模型资源)
 * - Web 组件 onInterceptRequest 回调:拦截 ark-tavern.local 资源请求
 * - 导入成功后注册资源,生成受控 URL(不调用 loadModel)
 * - 页面显示资源 URL / 大小 / MIME / 等待加载状态
 * - 不调用 JavaScript loadModel(Phase 1D-2B)
 * - 不替换默认 VRM
 *
 * Phase 1D-1 范围(已完成):
 * - 接入"导入模型"按钮(系统文件选择器)
 * - 显示导入状态、文件名、格式、大小、缓存准备状态、glTF 依赖状态
 * - 选择完成后仅显示"模型文件已准备,等待 Phase 1D-2 加载"
 *
 * 页面职责:
 * - 创建 ArkWebVrmViewerController
 * - 创建 ArkWebFileImportController(Phase 1D-1)
 * - 创建 ArkWebModelResourceProvider(Phase 1D-2A)
 * - 挂载 Web 组件渲染区域 + onInterceptRequest
 * - 显示状态与错误
 * - 连接聚焦/重置按钮(调用 resetCamera)
 * - 连接"导入模型"按钮(调用 pickModelFile + registerFile)
 * - 页面销毁时调用 dispose
 *
 * 结构(Stack overlay,预览区域始终不被压缩):
 * Stack
 * ├── 全屏预览区域(Web 组件,最底层,100% 尺寸)
 * ├── 顶部工具栏(返回 / 模型名 / 普通·演示模式 / 更多)
 * ├── 右侧快捷工具栏(聚焦 / 重置 / 截图 / 设置)
 * └── 底部控制抽屉(模型 / 姿势 / 动画 / 表情 / 物理 / 场景 / 调试)
 *
 * Reference:
 * - figure-main: index.html (整体页面结构与工具栏)
 * - ownverse-vrm-viewer: analysis/VIEWER_ARCHITECTURE.md (UI 层绑定)
 * - HarmonyOS ArkWeb: Web 组件 + WebviewController + onInterceptRequest
 * - HarmonyOS CoreFileKit: DocumentViewPicker / fileIo (Phase 1D-1)
 */

import { router, promptAction } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import {
  ArkWebViewerConfig,
  ArkWebViewerState
} from '../vrmviewer/ArkWebVrmViewerTypes';
import {
  ArkWebViewerEventListener,
  ArkWebVrmViewerController
} from '../vrmviewer/ArkWebVrmViewerController';
import {
  ArkWebFileImportController
} from '../vrmviewer/ArkWebFileImportController';
import {
  GltfDependencyState,
  ImportedModelFile,
  ModelImportState
} from '../vrmviewer/ArkWebModelImportTypes';
import {
  ArkWebModelResourceProvider
} from '../vrmviewer/ArkWebModelResourceProvider';
import {
  ModelResourceProbeState,
  ModelResourceState,
  WebModelResource
} from '../vrmviewer/ArkWebModelResourceTypes';

/** 查看器模式 */
enum ViewerMode {
  Normal = 'normal',
  Presentation = 'presentation'
}

/** 抽屉状态 */
enum DrawerState {
  Collapsed = 'collapsed',
  Half = 'half',
  Expanded = 'expanded'
}

/** 抽屉 Tab */
enum ViewerTab {
  Model = 'model',
  Pose = 'pose',
  Animation = 'animation',
  Expression = 'expression',
  Physics = 'physics',
  Scene = 'scene',
  Debug = 'debug'
}

/**
 * ArkWeb Viewer 事件监听器包装。
 *
 * ArkTS struct 不能 implements 接口,通过此包装类持有回调函数,
 * 让 VrmViewerPage 在 aboutToAppear 中注入闭包更新 @State。
 */
class ViewerEventListener implements ArkWebViewerEventListener {
  onStateChangedFn: ((state: ArkWebViewerState, detail: string) => void) | null = null;
  onErrorFn: ((code: string, message: string) => void) | null = null;

  onStateChanged(state: ArkWebViewerState, detail: string): void {
    const fn = this.onStateChangedFn;
    if (fn !== null) {
      fn(state, detail);
    }
  }

  onError(code: string, message: string): void {
    const fn = this.onErrorFn;
    if (fn !== null) {
      fn(code, message);
    }
  }
}

@Entry
@Component
struct VrmViewerPage {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navigationBarHeight') navigationBarHeight: number = 0;

  // ===== UI 状态 =====
  @State viewerMode: ViewerMode = ViewerMode.Normal;
  @State activeTab: ViewerTab = ViewerTab.Model;
  @State drawerState: DrawerState = DrawerState.Half;
  @State backgroundOption: string = '#1A1A1A';
  @State showGrid: boolean = false;
  @State lightIntensity: number = 75;
  @State lastMessage: string = '';

  /** 页面高度(由根 Stack onAreaChange 捕获,用于计算抽屉高度) */
  @State pageHeight: number = 0;
  /** 预览区域高度(始终等于 pageHeight,用于验收报告) */
  @State previewHeight: number = 0;

  // ===== ArkWeb Viewer 状态(由 Controller 通过 Listener 回调更新) =====
  @State viewerState: ArkWebViewerState = ArkWebViewerState.UNINITIALIZED;
  @State viewerDetail: string = '未初始化';
  @State lastErrorCode: string = '';
  @State lastError: string = '';
  /** Web 组件是否已加载完成(用于触发 Web 重建) */
  @State webLoaded: boolean = false;

  // ===== Phase 1D-1: 模型导入状态 =====
  /** 导入状态机(由 ImportController 驱动,通过轮询同步到 @State) */
  @State importState: ModelImportState = ModelImportState.IDLE;
  /** 当前已导入的文件元数据(成功后非 null) */
  @State importedFile: ImportedModelFile | null = null;
  /** 最近一次导入错误消息(空字符串表示无错误) */
  @State importLastError: string = '';
  /** 是否正在导入(防止重复点击) */
  @State importInProgress: boolean = false;

  // ===== Phase 1D-2A: 资源暴露状态 =====
  /** 资源 Provider 状态(EMPTY / READY / DISPOSED) */
  @State resourceState: ModelResourceState = ModelResourceState.EMPTY;
  /** 当前已注册的公共资源(可安全传给 JavaScript,不含 cachePath) */
  @State preparedResource: WebModelResource | null = null;
  /** 资源准备错误消息(空字符串表示无错误) */
  @State resourceLastError: string = '';

  // ===== Phase 1D-2B-1: 资源探测状态 =====
  /** 探测状态机(NOT_PROBED / PROBING / VERIFIED / FAILED) */
  @State probeState: ModelResourceProbeState = ModelResourceProbeState.NOT_PROBED;
  /** 探测 HTTP 状态码(HEAD 200 = 成功;失败时为 0 或具体错误码) */
  @State probeStatusCode: number = 0;
  /** 探测响应 Content-Type(成功时与资源 MIME 一致) */
  @State probeMimeType: string = '';
  /** 探测响应 Content-Length(成功时与资源大小一致) */
  @State probeContentLength: number = -1;
  /** 探测响应 X-ArkTavern-Resource-Id(成功时与资源 ID 一致) */
  @State probeResourceId: string = '';
  /** 探测是否发生重定向(应为 false) */
  @State probeRedirected: boolean = false;
  /** 探测错误码(成功时为空字符串) */
  @State probeErrorCode: string = '';
  /** 探测错误消息(成功时为空字符串) */
  @State probeErrorMessage: string = '';
  /** 探测完成时间戳(ms,0 表示未探测) */
  @State probeVerifiedAt: number = 0;
  /** 是否正在探测(防止重复点击 + 轮询控制) */
  @State probeInProgress: boolean = false;
  /** 轮询计时器 ID(-1 表示无轮询) */
  private probePollTimerId: number = -1;
  /** 轮询间隔(ms) */
  private readonly PROBE_POLL_INTERVAL_MS: number = 200;
  /** 轮询最大次数(20 × 200ms = 4s 超时) */
  private readonly PROBE_POLL_MAX_COUNT: number = 20;
  /** 当前轮询次数 */
  private probePollCount: number = 0;

  // ===== Phase 1D-2B-2: 用户模型加载状态 =====
  /** 加载状态机(NOT_REQUESTED / LOADING / READY / FAILED) */
  @State loadState: string = 'NOT_REQUESTED';
  /** 是否正在加载(防止重复点击 + 轮询控制) */
  @State loadInProgress: boolean = false;
  /** 加载目标文件名(来自 preparedResource.displayName) */
  @State loadDisplayName: string = '';
  /** 加载完成后当前模型显示名 */
  @State loadModelDisplayName: string = '';
  /** 加载错误码(成功时为空字符串) */
  @State loadErrorCode: string = '';
  /** 加载错误消息(成功时为空字符串) */
  @State loadErrorMessage: string = '';
  /** 加载开始时间戳(ms,0 表示未加载) */
  @State loadStartedAt: number = 0;
  /** 加载完成时间戳(ms,0 表示未完成) */
  @State loadCompletedAt: number = 0;
  /** 加载结果轮询计时器 ID(-1 表示无轮询) */
  private loadPollTimerId: number = -1;
  /** 加载结果轮询间隔(ms) */
  private readonly LOAD_POLL_INTERVAL_MS: number = 250;
  /** 加载结果轮询最大次数(240 × 250ms = 60s 超时) */
  private readonly LOAD_POLL_MAX_COUNT: number = 240;
  /** 当前加载结果轮询次数 */
  private loadPollCount: number = 0;

  // ===== Controller 实例(非 @State,不参与 UI 渲染) =====
  private arkWebController: ArkWebVrmViewerController = new ArkWebVrmViewerController();
  /** 模型导入控制器(Phase 1D-1,在 aboutToAppear 中创建) */
  private importController: ArkWebFileImportController | null = null;
  /** 缓存模型资源提供者(Phase 1D-2A,在 aboutToAppear 中创建) */
  private resourceProvider: ArkWebModelResourceProvider | null = null;
  /** 事件监听器包装器(注入闭包更新 @State) */
  private eventListener: ViewerEventListener = new ViewerEventListener();

  /** 抽屉标题区(拖动条 + 标题)固定高度 */
  private readonly DRAWER_HEADER_HEIGHT: number = 60;

  aboutToAppear(): void {
    // 注入闭包:Controller 回调 → 更新 @State
    this.eventListener.onStateChangedFn = (state: ArkWebViewerState, detail: string) => {
      this.viewerState = state;
      this.viewerDetail = detail;
    };
    this.eventListener.onErrorFn = (code: string, message: string) => {
      this.lastErrorCode = code;
      this.lastError = message;
    };
    this.arkWebController.setEventListener(this.eventListener);

    this.viewerState = ArkWebViewerState.UNINITIALIZED;
    this.viewerDetail = '正在加载 Web Viewer...';

    // Phase 1D-1:创建模型导入控制器(需要 UIAbilityContext 用于 cacheDir 和 Picker)
    if (this.importController === null) {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      this.importController = new ArkWebFileImportController(ctx);

      // Phase 1D-2A:创建资源 Provider(使用同一 context 的 cacheDir)
      // importDirectory = <cacheDir>/vrm-imports(与 ImportController 一致)
      this.resourceProvider = new ArkWebModelResourceProvider(ctx.cacheDir);
    }

    // Web 组件加载由 build() 触发,初始化在 onPageEnd 回调中完成
  }

  aboutToDisappear(): void {
    this.disposeViewer();
  }

  /**
   * 销毁 Viewer,释放所有资源。
   *
   * Phase 1D-2B-2 销毁顺序(AGENTS.md Phase 1D-2B-2 §二十二 页面销毁):
   * 1. 停止用户模型加载结果轮询
   * 2. 停止资源探测轮询
   * 3. Viewer dispose(使 ViewerModelLoader.loadGeneration 失效)
   * 4. clearPreparedModelLoadResult — 清除加载协调器状态
   * 5. clearModelResourceProbe — 清除探测状态
   * 6. resourceProvider.dispose — 停止响应资源请求
   * 7. importController.dispose — 标记导入控制器销毁
   *
   * Phase 1D-2B-1 销毁顺序(原始):
   * 1. clearModelResourceProbe() — 停止探测轮询,清除探测状态
   * 2. resourceProvider.dispose() — 停止响应资源请求
   * 3. importController.dispose() — 标记导入控制器销毁
   * 4. arkWebController.destroy() — 销毁 Web Viewer
   *
   * Phase 1D-1:
   * - 保留已缓存的 currentFile(避免页面短暂切换造成文件丢失)
   *
   * 不删除缓存文件(由 ArkWebFileImportController 负责)。
   *
   * Reference:
   * - figure-main: disposeVrm (资源释放)
   * - ownverse-vrm-viewer: RESOURCE_LIFECYCLE.md (避免已知泄漏)
   * - AGENTS.md Phase 1D-2B-2 §二十二 页面销毁顺序
   */
  private disposeViewer(): void {
    // Phase 1D-2B-2:1. 停止用户模型加载结果轮询
    this.stopLoadPolling();
    this.resetLoadState();
    // Phase 1D-2B-2:2. 停止资源探测轮询
    this.stopProbePolling();
    this.resetProbeState();
    // Phase 1D-2B-2:3. Viewer dispose 先触发(使 ViewerModelLoader.loadGeneration 失效,
    //                正在进行的加载结果会因代次检查被忽略)
    // Phase 1D-2B-2:4. clearPreparedModelLoadResult(异步,不等待)
    this.arkWebController.clearPreparedModelLoadResult().then((_r: string) => {
      console.info('[VrmViewerPage] clearPreparedModelLoadResult done on dispose');
    }).catch((e: Object) => {
      console.warn('[VrmViewerPage] clearPreparedModelLoadResult failed: ' + (e instanceof Error ? e.message : String(e)));
    });
    // Phase 1D-2B-1:5. clearModelResourceProbe(异步,不等待)
    this.arkWebController.clearModelResourceProbe().then((_r: string) => {
      console.info('[VrmViewerPage] clearModelResourceProbe done on dispose');
    }).catch((e: Object) => {
      console.warn('[VrmViewerPage] clearModelResourceProbe failed: ' + (e instanceof Error ? e.message : String(e)));
    });
    // Phase 1D-2A:6. 再销毁资源 Provider(停止响应拦截请求)
    if (this.resourceProvider !== null) {
      this.resourceProvider.dispose();
      this.resourceProvider = null;
    }
    // Phase 1D-1:7. 再销毁导入控制器
    if (this.importController !== null) {
      this.importController.dispose();
    }
    // 最后销毁 Web Viewer
    this.arkWebController.destroy();
    this.webLoaded = false;
  }

  /** 计算抽屉高度 */
  private getDrawerHeight(): number {
    if (this.pageHeight <= 0) {
      return this.DRAWER_HEADER_HEIGHT;
    }
    if (this.drawerState === DrawerState.Collapsed) {
      return this.DRAWER_HEADER_HEIGHT;
    } else if (this.drawerState === DrawerState.Half) {
      return Math.max(this.DRAWER_HEADER_HEIGHT, Math.round(this.pageHeight * 0.4));
    } else {
      return Math.max(this.DRAWER_HEADER_HEIGHT, Math.round(this.pageHeight * 0.7));
    }
  }

  /** 抽屉状态显示标签 */
  private drawerStateLabel(): string {
    if (this.drawerState === DrawerState.Collapsed) {
      return '收起';
    } else if (this.drawerState === DrawerState.Half) {
      return '半展开';
    } else {
      return '展开';
    }
  }

  /** 切换抽屉状态:collapsed → half → expanded → collapsed */
  private cycleDrawerState(): void {
    if (this.drawerState === DrawerState.Collapsed) {
      this.drawerState = DrawerState.Half;
    } else if (this.drawerState === DrawerState.Half) {
      this.drawerState = DrawerState.Expanded;
    } else {
      this.drawerState = DrawerState.Collapsed;
    }
  }

  /** 显示占位提示(快捷工具栏 / 更多 按钮) */
  private showPlaceholderToast(): void {
    this.lastMessage = '该功能将在后续阶段启用';
    promptAction.showToast({ message: '该功能将在后续阶段启用' });
  }

  /** 聚焦按钮:重置相机到默认位置(Phase 1B) */
  private onFocusButton(): void {
    this.arkWebController.resetCamera();
    promptAction.showToast({ message: '已聚焦' });
  }

  /** 重置按钮:重置相机到默认位置(Phase 1B,与聚焦行为相同) */
  private onResetButton(): void {
    this.arkWebController.resetCamera();
    promptAction.showToast({ message: '已重置' });
  }

  /**
   * "导入模型"按钮:调用系统文件选择器并复制到受控缓存。
   *
   * Phase 1D-2A:
   * - 导入成功后调用 resourceProvider.registerFile(file)
   * - 生成受控资源 URL(不调用 loadModel)
   * - 资源注册失败:保留缓存文件,默认模型继续显示
   *
   * Phase 1D-1:
   * - 调用 importController.pickModelFile()
   * - 成功:显示"模型文件已准备,等待加载"
   * - 用户取消:显示"已取消选择"(非错误)
   * - 失败:显示错误信息
   * - 不调用 JavaScript loadModel
   * - 不替换默认 VRM
   */
  private async onImportModelButton(): Promise<void> {
    if (this.importController === null) {
      promptAction.showToast({ message: '导入控制器未初始化' });
      return;
    }
    if (this.importInProgress) {
      // 已有操作进行中,忽略重复点击
      return;
    }
    // Phase 1D-2B-2:用户模型加载期间禁止导入新模型
    if (this.loadInProgress) {
      promptAction.showToast({ message: '模型加载中,请稍候' });
      return;
    }
    this.importInProgress = true;
    this.importState = ModelImportState.PICKING;
    try {
      const result: ImportedModelFile | null = await this.importController.pickModelFile();
      // 同步状态到 @State
      this.importState = this.importController.getState();
      this.importLastError = this.importController.getLastError();
      this.importedFile = this.importController.getCurrentFile();

      if (result === null) {
        // 用户取消或失败
        if (this.importState === ModelImportState.CANCELLED) {
          promptAction.showToast({ message: '已取消选择' });
        } else if (this.importState === ModelImportState.FAILED) {
          promptAction.showToast({ message: `导入失败: ${this.importLastError}` });
        }
        // STALE_IMPORT_RESULT / DISPOSED 静默处理
      } else {
        // Phase 1D-2A:导入成功后注册资源(生成受控 URL)
        this.registerImportedResource(result);
        // 不调用 loadModel(Phase 1D-2B)
        // 不替换默认 VRM
        promptAction.showToast({ message: '模型文件已准备,等待加载' });
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.importState = ModelImportState.FAILED;
      this.importLastError = msg;
      promptAction.showToast({ message: `导入异常: ${msg}` });
    } finally {
      this.importInProgress = false;
    }
  }

  /**
   * 注册已导入的模型文件到资源 Provider(Phase 1D-2A)。
   *
   * 失败处理:
   * - 保留缓存文件(ImportController currentFile 保留)
   * - 默认模型继续显示
   * - Provider state 保持 EMPTY
   * - 页面显示资源准备失败
   *
   * 成功后调用 `prepareModelResource` Bridge:
   * - 把资源元数据传给 Web 端 keeper(只含白名单字段)
   * - 不触发任何模型加载行为
   * - Bridge 失败仅记录日志,不影响 Provider 状态
   *
   * @param file 已导入的模型文件
   */
  private registerImportedResource(file: ImportedModelFile): void {
    if (this.resourceProvider === null) {
      this.resourceState = ModelResourceState.EMPTY;
      this.preparedResource = null;
      this.resourceLastError = 'resourceProvider not initialized';
      return;
    }
    try {
      const resource: WebModelResource = this.resourceProvider.registerFile(file);
      this.preparedResource = resource;
      this.resourceState = this.resourceProvider.getState();
      this.resourceLastError = '';
      console.info(`[VrmViewerPage] resource ready: url=${resource.resourceUrl}`);

      // Phase 1D-2A:同步资源元数据到 Web 端 keeper(不触发加载)
      // 只含白名单字段,cachePath / sourceUri 永远不会传给 JavaScript
      this.notifyPreparedResourceToWeb(resource);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.preparedResource = null;
      this.resourceState = this.resourceProvider.getState();
      this.resourceLastError = msg;
      console.error(`[VrmViewerPage] registerResource failed: ${msg}`);
    }
  }

  /**
   * 把资源元数据传给 Web 端 keeper(Phase 1D-2A)。
   *
   * - 构造 JSON 字符串(只含白名单字段:resourceUrl / displayName / mimeType / size / extension)
   * - 调用 arkWebController.prepareModelResource(resourceJson)
   * - 异步,不等待,失败仅日志
   * - 严格不调用 loadModel() / replaceModel()
   */
  private notifyPreparedResourceToWeb(resource: WebModelResource): void {
    const payload: Record<string, Object> = {
      'resourceUrl': resource.resourceUrl,
      'displayName': resource.displayName,
      'mimeType': resource.mimeType,
      'size': resource.size,
      'extension': resource.extension
    };
    let resourceJson: string;
    try {
      resourceJson = JSON.stringify(payload);
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.error(`[VrmViewerPage] serialize preparedResource failed: ${msg}`);
      return;
    }
    // 异步调用,不等待,失败仅记录日志
    this.arkWebController.prepareModelResource(resourceJson).then((result: string) => {
      console.info(`[VrmViewerPage] prepareModelResource result: ${result}`);
    }).catch((e: Object) => {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[VrmViewerPage] prepareModelResource failed: ${msg}`);
    });
  }

  /**
   * "清除缓存文件"按钮:删除当前已导入的缓存文件。
   *
   * Phase 1D-2B-1 清除顺序(AGENTS.md §十六):
   * 1. clearModelResourceProbe() — 清除探测状态(异步,不等待)
   * 2. clearPreparedModelResource() — 清除 Web 端 keeper 资源元数据(异步,不等待)
   * 3. resourceProvider.unregisterCurrent() — 停止资源响应
   * 4. importController.clearCurrentFile() — 删除缓存文件
   *
   * Phase 1D-2A:
   * - 先调用 resourceProvider.unregisterCurrent()(停止资源响应)
   * - 再调用 importController.clearCurrentFile()(删除缓存文件)
   *
   * Phase 1D-1:
   * - 调用 importController.clearCurrentFile()
   * - 删除受控缓存文件
   * - 恢复 IDLE 状态
   */
  private async onClearImportButton(): Promise<void> {
    if (this.importController === null) {
      return;
    }
    if (this.importedFile === null) {
      promptAction.showToast({ message: '无缓存文件可清除' });
      return;
    }
    // Phase 1D-2B-2:用户模型加载期间禁止清除缓存
    if (this.loadInProgress) {
      promptAction.showToast({ message: '模型加载中,请稍候' });
      return;
    }
    // Phase 1D-2B-2:1. 停止加载结果轮询 + 重置加载状态
    this.stopLoadPolling();
    this.resetLoadState();
    // Phase 1D-2B-2:2. 清除 Web 端加载协调器状态(异步,不等待)
    this.arkWebController.clearPreparedModelLoadResult().then((result: string) => {
      console.info(`[VrmViewerPage] clearPreparedModelLoadResult result: ${result}`);
    }).catch((e: Object) => {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[VrmViewerPage] clearPreparedModelLoadResult failed: ${msg}`);
    });
    // Phase 1D-2B-1:1. 停止探测轮询 + 重置探测状态
    this.stopProbePolling();
    this.resetProbeState();
    // Phase 1D-2B-1:2. 清除 Web 端探测状态(异步,不等待)
    this.arkWebController.clearModelResourceProbe().then((result: string) => {
      console.info(`[VrmViewerPage] clearModelResourceProbe result: ${result}`);
    }).catch((e: Object) => {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[VrmViewerPage] clearModelResourceProbe failed: ${msg}`);
    });
    // Phase 1D-2B-1:3. 清除 Web 端 keeper 资源元数据(异步,不等待)
    this.arkWebController.clearPreparedModelResource().then((result: string) => {
      console.info(`[VrmViewerPage] clearPreparedModelResource result: ${result}`);
    }).catch((e: Object) => {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[VrmViewerPage] clearPreparedModelResource failed: ${msg}`);
    });
    // Phase 1D-2B-1:4. 注销资源(避免缓存文件已删除但 Provider 仍尝试读取)
    if (this.resourceProvider !== null) {
      this.resourceProvider.unregisterCurrent();
      this.preparedResource = null;
      this.resourceState = this.resourceProvider.getState();
    }
    // Phase 1D-2B-1:5. 删除缓存文件
    await this.importController.clearCurrentFile();
    this.importState = this.importController.getState();
    this.importedFile = this.importController.getCurrentFile();
    this.importLastError = this.importController.getLastError();
    promptAction.showToast({ message: '已清除缓存文件' });
  }

  // ===== Phase 1D-2B-1: 资源探测(HEAD 请求校验) =====

  /**
   * "验证资源"按钮:启动 HEAD 请求探测,校验受控资源 URL 是否可正常访问。
   *
   * 流程:
   * 1. 检查前置条件:WebModelResource != null && Viewer READY && !probeInProgress
   * 2. 调用 probePreparedModelResource() 同步启动探测
   * 3. 页面 @State probeState 推进到 PROBING
   * 4. 启动轮询,每 200ms 调用 getModelResourceProbeResult() 获取最终结果
   * 5. 检测到 VERIFIED / FAILED 状态时停止轮询
   * 6. 超时(4s)后强制停止,标记为 FAILED
   *
   * 严格不调用:
   * - GLTFLoader.load()
   * - ViewerModelLoader.loadModel()
   * - 不读取模型文件内容
   */
  private async onProbeResourceButton(): Promise<void> {
    // 前置条件检查
    if (this.preparedResource === null) {
      promptAction.showToast({ message: '请先准备资源' });
      return;
    }
    if (this.viewerState !== ArkWebViewerState.READY) {
      promptAction.showToast({ message: 'Viewer 未就绪' });
      return;
    }
    if (this.probeInProgress) {
      // 已有探测进行中,忽略重复点击
      return;
    }
    // Phase 1D-2B-2:用户模型加载期间禁止验证资源
    if (this.loadInProgress) {
      promptAction.showToast({ message: '模型加载中,请稍候' });
      return;
    }

    // 重置探测状态(保留上次结果作为参考?规范要求重置)
    this.resetProbeState();
    this.probeInProgress = true;
    this.probeState = ModelResourceProbeState.PROBING;
    this.probePollCount = 0;

    try {
      // 1. 启动探测(同步返回 PROBING)
      const startResult: string = await this.arkWebController.probePreparedModelResource();
      console.info(`[VrmViewerPage] probePreparedModelResource result: ${startResult}`);
      // 简单字符串匹配检查启动是否成功
      if (startResult.indexOf('"success":true') < 0 && startResult.indexOf('"success": true') < 0) {
        // 启动失败
        this.probeState = ModelResourceProbeState.FAILED;
        this.probeErrorCode = 'PROBE_START_FAILED';
        // 提取 error.message
        const errorMatch: RegExpMatchArray | null = startResult.match(/"message"\s*:\s*"([^"]*)"/);
        this.probeErrorMessage = errorMatch !== null && errorMatch.length >= 2 ? errorMatch[1] : startResult;
        this.probeVerifiedAt = Date.now();
        this.probeInProgress = false;
        promptAction.showToast({ message: `探测启动失败: ${this.probeErrorMessage}` });
        return;
      }
      // 2. 启动轮询,异步获取最终结果
      this.startProbePolling();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.probeState = ModelResourceProbeState.FAILED;
      this.probeErrorCode = 'PROBE_START_FAILED';
      this.probeErrorMessage = msg;
      this.probeVerifiedAt = Date.now();
      this.probeInProgress = false;
      promptAction.showToast({ message: `探测异常: ${msg}` });
    }
  }

  /**
   * 启动轮询:每 PROBE_POLL_INTERVAL_MS 检查一次探测结果。
   * 最多轮询 PROBE_POLL_MAX_COUNT 次,超时后标记为 FAILED。
   */
  private startProbePolling(): void {
    this.stopProbePolling();
    this.probePollTimerId = setTimeout(() => {
      this.pollProbeResultOnce();
    }, this.PROBE_POLL_INTERVAL_MS);
  }

  /**
   * 停止轮询(取消计时器,不重置状态)。
   */
  private stopProbePolling(): void {
    if (this.probePollTimerId >= 0) {
      clearTimeout(this.probePollTimerId);
      this.probePollTimerId = -1;
    }
  }

  /**
   * 执行一次轮询:调用 getModelResourceProbeResult() 检查探测状态。
   */
  private pollProbeResultOnce(): void {
    this.probePollTimerId = -1;
    if (!this.probeInProgress) {
      return;
    }
    this.probePollCount++;
    if (this.probePollCount > this.PROBE_POLL_MAX_COUNT) {
      // 超时
      this.probeState = ModelResourceProbeState.FAILED;
      this.probeErrorCode = 'PROBE_TIMEOUT';
      this.probeErrorMessage = `Probe timeout after ${this.PROBE_POLL_MAX_COUNT * this.PROBE_POLL_INTERVAL_MS}ms`;
      this.probeVerifiedAt = Date.now();
      this.probeInProgress = false;
      promptAction.showToast({ message: '探测超时' });
      return;
    }

    this.arkWebController.getModelResourceProbeResult().then((resultJson: string) => {
      this.handleProbeResultJson(resultJson);
    }).catch((e: Object) => {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[VrmViewerPage] pollProbeResult failed: ${msg}`);
      // 继续轮询(可能是临时错误)
      this.startProbePolling();
    });
  }

  /**
   * 解析轮询结果 JSON,更新 @State。
   * - result.state === 'PROBING':继续轮询
   * - result.state === 'VERIFIED':停止轮询,显示成功
   * - result.state === 'FAILED':停止轮询,显示错误
   */
  private handleProbeResultJson(resultJson: string): void {
    try {
      const parsed: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      const success: boolean = parsed['success'] === true;
      if (!success) {
        // Bridge 返回错误
        const errorObj: Record<string, Object> = parsed['error'] as Record<string, Object>;
        this.probeState = ModelResourceProbeState.FAILED;
        this.probeErrorCode = errorObj !== undefined && errorObj !== null
          ? (errorObj['code'] as string) : 'PROBE_BRIDGE_ERROR';
        this.probeErrorMessage = errorObj !== undefined && errorObj !== null
          ? (errorObj['message'] as string) : resultJson;
        this.probeVerifiedAt = Date.now();
        this.probeInProgress = false;
        promptAction.showToast({ message: `探测失败: ${this.probeErrorMessage}` });
        return;
      }
      const result: Record<string, Object> = parsed['result'] as Record<string, Object>;
      if (result === null || result === undefined) {
        // 还没有结果,继续轮询
        this.startProbePolling();
        return;
      }
      const stateStr: string = (result['state'] as string) || 'NOT_PROBED';
      if (stateStr === 'PROBING') {
        // 仍在探测中,继续轮询
        this.startProbePolling();
        return;
      }
      // 探测完成(VERIFIED / FAILED / NOT_PROBED / 其他)
      this.applyProbeResult(result, stateStr);
      this.probeInProgress = false;
      if (this.probeState === ModelResourceProbeState.VERIFIED) {
        promptAction.showToast({ message: '资源传输验证通过' });
      } else if (this.probeState === ModelResourceProbeState.FAILED) {
        promptAction.showToast({ message: `探测失败: ${this.probeErrorMessage}` });
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.error(`[VrmViewerPage] parse probe result failed: ${msg}, raw=${resultJson}`);
      // 解析失败视为错误
      this.probeState = ModelResourceProbeState.FAILED;
      this.probeErrorCode = 'PROBE_RESULT_PARSE_FAILED';
      this.probeErrorMessage = msg;
      this.probeVerifiedAt = Date.now();
      this.probeInProgress = false;
    }
  }

  /**
   * 将探测结果字段应用到 @State。
   */
  private applyProbeResult(result: Record<string, Object>, stateStr: string): void {
    // 解析状态枚举
    if (stateStr === 'VERIFIED') {
      this.probeState = ModelResourceProbeState.VERIFIED;
    } else if (stateStr === 'FAILED') {
      this.probeState = ModelResourceProbeState.FAILED;
    } else if (stateStr === 'PROBING') {
      this.probeState = ModelResourceProbeState.PROBING;
    } else {
      this.probeState = ModelResourceProbeState.NOT_PROBED;
    }
    // 解析字段(使用类型守卫避免 undefined / null)
    this.probeStatusCode = this.safeNumber(result['statusCode'], 0);
    this.probeMimeType = this.safeString(result['mimeType'], '');
    this.probeContentLength = this.safeNumber(result['contentLength'], -1);
    this.probeResourceId = this.safeString(result['resourceId'], '');
    this.probeRedirected = result['redirected'] === true;
    this.probeErrorCode = this.safeString(result['errorCode'], '');
    this.probeErrorMessage = this.safeString(result['errorMessage'], '');
    this.probeVerifiedAt = this.safeNumber(result['verifiedAt'], 0);
  }

  /**
   * 重置探测状态到 NOT_PROBED(不清除轮询计时器,由 stopProbePolling 负责)。
   */
  private resetProbeState(): void {
    this.probeState = ModelResourceProbeState.NOT_PROBED;
    this.probeStatusCode = 0;
    this.probeMimeType = '';
    this.probeContentLength = -1;
    this.probeResourceId = '';
    this.probeRedirected = false;
    this.probeErrorCode = '';
    this.probeErrorMessage = '';
    this.probeVerifiedAt = 0;
    this.probePollCount = 0;
  }

  /** 安全读取 number 字段(失败返回 defaultValue)。 */
  private safeNumber(value: Object | undefined, defaultValue: number): number {
    if (typeof value === 'number') {
      return value;
    }
    return defaultValue;
  }

  /** 安全读取 string 字段(失败返回 defaultValue)。 */
  private safeString(value: Object | undefined, defaultValue: string): string {
    if (typeof value === 'string') {
      return value;
    }
    return defaultValue;
  }

  /** 探测状态显示标签 */
  private probeStateLabel(): string {
    if (this.probeState === ModelResourceProbeState.NOT_PROBED) {
      return '未探测';
    } else if (this.probeState === ModelResourceProbeState.PROBING) {
      return '探测中...';
    } else if (this.probeState === ModelResourceProbeState.VERIFIED) {
      return '验证通过';
    } else if (this.probeState === ModelResourceProbeState.FAILED) {
      return '探测失败';
    }
    return '未知';
  }

  /** 探测验证时间显示(格式化为人类可读) */
  private probeVerifiedAtLabel(): string {
    if (this.probeVerifiedAt <= 0) {
      return '—';
    }
    const date: Date = new Date(this.probeVerifiedAt);
    const h: number = date.getHours();
    const m: number = date.getMinutes();
    const s: number = date.getSeconds();
    const hh: string = h < 10 ? `0${h}` : `${h}`;
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const ss: string = s < 10 ? `0${s}` : `${s}`;
    return `${hh}:${mm}:${ss}`;
  }

  // ===== Phase 1D-2B-2: 用户模型加载(GLTFLoader 实际加载与原子替换) =====

  /**
   * "加载模型"按钮:启动用户模型加载流程。
   *
   * 流程(AGENTS.md Phase 1D-2B-2 §二十一):
   * 1. 前置条件检查:PreparedResource 存在 / Viewer READY / ProbeState VERIFIED / !loadInProgress / !probeInProgress
   * 2. 调用 loadPreparedModelResource() 同步启动加载
   * 3. 页面状态改为 LOADING
   * 4. 每 250ms 查询 getPreparedModelLoadResult()
   * 5. READY / FAILED 时停止轮询
   * 6. 最长等待 60 秒(LOAD_POLL_MAX_COUNT × LOAD_POLL_INTERVAL_MS)
   *
   * 严格不:
   * - 不接受 URL 参数(由 Bridge 从 PreparedModelResourceKeeper 读取)
   * - 不直接调用 GLTFLoader.load()
   * - 不直接调用 fetch / arrayBuffer / blob
   *
   * 失败时(AGENTS.md Phase 1D-2B-2 §二十三):
   * - Provider 保持 READY
   * - PreparedResource 保持
   * - ProbeResult 保持 VERIFIED
   * - 当前模型保持显示
   * - 用户可再次点击"加载模型"
   */
  private async onLoadModelButton(): Promise<void> {
    // 前置条件检查
    if (this.preparedResource === null) {
      promptAction.showToast({ message: '请先准备资源' });
      return;
    }
    if (this.viewerState !== ArkWebViewerState.READY) {
      promptAction.showToast({ message: 'Viewer 未就绪' });
      return;
    }
    if (this.probeState !== ModelResourceProbeState.VERIFIED) {
      promptAction.showToast({ message: '请先验证资源' });
      return;
    }
    if (this.probeInProgress) {
      // 探测进行中,禁止加载
      return;
    }
    if (this.loadInProgress) {
      // 已有加载进行中,忽略重复点击
      return;
    }

    // 重置加载状态并启动加载
    this.resetLoadState();
    this.loadInProgress = true;
    this.loadState = 'LOADING';
    this.loadStartedAt = Date.now();
    this.loadPollCount = 0;
    // 显示目标文件名
    if (this.preparedResource !== null) {
      this.loadDisplayName = this.preparedResource.displayName;
    }

    try {
      // 1. 启动加载(同步返回 LOADING 或 FAILED 结果)
      const startResult: string = await this.arkWebController.loadPreparedModelResource();
      console.info(`[VrmViewerPage] loadPreparedModelResource result: ${startResult}`);
      // 简单字符串匹配检查启动是否成功
      if (startResult.indexOf('"success":true') < 0 && startResult.indexOf('"success": true') < 0) {
        // 启动失败:解析错误信息
        this.loadState = 'FAILED';
        this.loadErrorCode = 'LOAD_START_FAILED';
        const errorMatch: RegExpMatchArray | null = startResult.match(/"message"\s*:\s*"([^"]*)"/);
        this.loadErrorMessage = errorMatch !== null && errorMatch.length >= 2 ? errorMatch[1] : startResult;
        this.loadCompletedAt = Date.now();
        this.loadInProgress = false;
        promptAction.showToast({ message: `模型加载失败,当前模型已保留` });
        return;
      }
      // 2. 启动轮询,异步获取最终结果
      this.startLoadPolling();
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      this.loadState = 'FAILED';
      this.loadErrorCode = 'LOAD_START_FAILED';
      this.loadErrorMessage = msg;
      this.loadCompletedAt = Date.now();
      this.loadInProgress = false;
      promptAction.showToast({ message: `模型加载失败,当前模型已保留` });
    }
  }

  /**
   * 启动加载结果轮询:每 LOAD_POLL_INTERVAL_MS 检查一次加载结果。
   * 最多轮询 LOAD_POLL_MAX_COUNT 次,超时后标记为 FAILED。
   */
  private startLoadPolling(): void {
    this.stopLoadPolling();
    this.loadPollTimerId = setTimeout(() => {
      this.pollLoadResultOnce();
    }, this.LOAD_POLL_INTERVAL_MS);
  }

  /**
   * 停止加载结果轮询(取消计时器,不重置状态)。
   */
  private stopLoadPolling(): void {
    if (this.loadPollTimerId >= 0) {
      clearTimeout(this.loadPollTimerId);
      this.loadPollTimerId = -1;
    }
  }

  /**
   * 执行一次加载结果轮询:调用 getPreparedModelLoadResult() 检查加载状态。
   */
  private pollLoadResultOnce(): void {
    this.loadPollTimerId = -1;
    if (!this.loadInProgress) {
      return;
    }
    this.loadPollCount++;
    if (this.loadPollCount > this.LOAD_POLL_MAX_COUNT) {
      // 超时
      this.loadState = 'FAILED';
      this.loadErrorCode = 'LOAD_TIMEOUT';
      this.loadErrorMessage = `Load timeout after ${this.LOAD_POLL_MAX_COUNT * this.LOAD_POLL_INTERVAL_MS}ms`;
      this.loadCompletedAt = Date.now();
      this.loadInProgress = false;
      promptAction.showToast({ message: '模型加载失败,当前模型已保留' });
      return;
    }

    this.arkWebController.getPreparedModelLoadResult().then((resultJson: string) => {
      this.handleLoadResultJson(resultJson);
    }).catch((e: Object) => {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.warn(`[VrmViewerPage] pollLoadResult failed: ${msg}`);
      // 继续轮询(可能是临时错误)
      this.startLoadPolling();
    });
  }

  /**
   * 解析加载结果 JSON,更新 @State。
   * - result.state === 'LOADING':继续轮询
   * - result.state === 'READY':停止轮询,显示成功
   * - result.state === 'FAILED':停止轮询,显示错误
   * - result.state === 'DISPOSED':停止轮询,显示销毁
   */
  private handleLoadResultJson(resultJson: string): void {
    try {
      const parsed: Record<string, Object> = JSON.parse(resultJson) as Record<string, Object>;
      const success: boolean = parsed['success'] === true;
      if (!success) {
        // Bridge 返回错误
        const errorObj: Record<string, Object> = parsed['error'] as Record<string, Object>;
        this.loadState = 'FAILED';
        this.loadErrorCode = errorObj !== undefined && errorObj !== null
          ? (errorObj['code'] as string) : 'LOAD_BRIDGE_ERROR';
        this.loadErrorMessage = errorObj !== undefined && errorObj !== null
          ? (errorObj['message'] as string) : resultJson;
        this.loadCompletedAt = Date.now();
        this.loadInProgress = false;
        promptAction.showToast({ message: '模型加载失败,当前模型已保留' });
        return;
      }
      const result: Record<string, Object> = parsed['result'] as Record<string, Object>;
      if (result === null || result === undefined) {
        // 还没有结果,继续轮询
        this.startLoadPolling();
        return;
      }
      const stateStr: string = (result['state'] as string) || 'NOT_REQUESTED';
      if (stateStr === 'LOADING' || stateStr === 'NOT_REQUESTED') {
        // 仍在加载中(或刚启动还未推进),继续轮询
        this.startLoadPolling();
        return;
      }
      // 加载完成(READY / FAILED / DISPOSED / 其他)
      this.applyLoadResult(result, stateStr);
      this.loadInProgress = false;
      if (this.loadState === 'READY') {
        promptAction.showToast({ message: '用户模型加载成功' });
      } else if (this.loadState === 'FAILED') {
        promptAction.showToast({ message: '模型加载失败,当前模型已保留' });
      }
    } catch (e) {
      const msg: string = e instanceof Error ? e.message : String(e);
      console.error(`[VrmViewerPage] parse load result failed: ${msg}, raw=${resultJson}`);
      // 解析失败视为错误
      this.loadState = 'FAILED';
      this.loadErrorCode = 'LOAD_RESULT_PARSE_FAILED';
      this.loadErrorMessage = msg;
      this.loadCompletedAt = Date.now();
      this.loadInProgress = false;
      promptAction.showToast({ message: '模型加载失败,当前模型已保留' });
    }
  }

  /**
   * 将加载结果字段应用到 @State。
   */
  private applyLoadResult(result: Record<string, Object>, stateStr: string): void {
    // 解析状态枚举
    if (stateStr === 'READY') {
      this.loadState = 'READY';
    } else if (stateStr === 'FAILED') {
      this.loadState = 'FAILED';
    } else if (stateStr === 'DISPOSED') {
      this.loadState = 'DISPOSED';
    } else if (stateStr === 'LOADING') {
      this.loadState = 'LOADING';
    } else {
      this.loadState = 'NOT_REQUESTED';
    }
    // 解析字段(使用类型守卫避免 undefined / null)
    this.loadDisplayName = this.safeString(result['displayName'], this.loadDisplayName);
    this.loadModelDisplayName = this.safeString(result['modelDisplayName'], '');
    this.loadErrorCode = this.safeString(result['errorCode'], '');
    this.loadErrorMessage = this.safeString(result['errorMessage'], '');
    this.loadStartedAt = this.safeNumber(result['startedAt'], this.loadStartedAt);
    this.loadCompletedAt = this.safeNumber(result['completedAt'], 0);
  }

  /**
   * 重置加载状态到 NOT_REQUESTED(不清除轮询计时器,由 stopLoadPolling 负责)。
   */
  private resetLoadState(): void {
    this.loadState = 'NOT_REQUESTED';
    this.loadDisplayName = '';
    this.loadModelDisplayName = '';
    this.loadErrorCode = '';
    this.loadErrorMessage = '';
    this.loadStartedAt = 0;
    this.loadCompletedAt = 0;
    this.loadPollCount = 0;
  }

  /** 加载状态显示标签 */
  private loadStateLabel(): string {
    if (this.loadState === 'NOT_REQUESTED') {
      return '未加载';
    } else if (this.loadState === 'LOADING') {
      return '加载中...';
    } else if (this.loadState === 'READY') {
      return '加载成功';
    } else if (this.loadState === 'FAILED') {
      return '加载失败';
    } else if (this.loadState === 'DISPOSED') {
      return '已销毁';
    }
    return '未知';
  }

  /** 加载开始时间显示(格式化为人类可读) */
  private loadStartedAtLabel(): string {
    if (this.loadStartedAt <= 0) {
      return '—';
    }
    const date: Date = new Date(this.loadStartedAt);
    const h: number = date.getHours();
    const m: number = date.getMinutes();
    const s: number = date.getSeconds();
    const hh: string = h < 10 ? `0${h}` : `${h}`;
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const ss: string = s < 10 ? `0${s}` : `${s}`;
    return `${hh}:${mm}:${ss}`;
  }

  /** 加载完成时间显示(格式化为人类可读) */
  private loadCompletedAtLabel(): string {
    if (this.loadCompletedAt <= 0) {
      return '—';
    }
    const date: Date = new Date(this.loadCompletedAt);
    const h: number = date.getHours();
    const m: number = date.getMinutes();
    const s: number = date.getSeconds();
    const hh: string = h < 10 ? `0${h}` : `${h}`;
    const mm: string = m < 10 ? `0${m}` : `${m}`;
    const ss: string = s < 10 ? `0${s}` : `${s}`;
    return `${hh}:${mm}:${ss}`;
  }

  /** 模型名称(顶部工具栏显示) */
  private modelDisplayName(): string {
    if (this.viewerState === ArkWebViewerState.UNINITIALIZED) {
      return '初始化中...';
    } else if (this.viewerState === ArkWebViewerState.INITIALIZING) {
      return '初始化中...';
    } else if (this.viewerState === ArkWebViewerState.LOADING_MODEL) {
      return '加载中...';
    } else if (this.viewerState === ArkWebViewerState.READY) {
      return 'VRM Viewer';
    } else if (this.viewerState === ArkWebViewerState.MODEL_READY) {
      return 'VRM 模型';
    } else if (this.viewerState === ArkWebViewerState.FAILED) {
      return '加载失败';
    } else if (this.viewerState === ArkWebViewerState.DISPOSED) {
      return '已销毁';
    } else {
      return '未加载';
    }
  }

  build() {
    Stack() {
      // ===== 1. 全屏预览区域(最底层,始终 100% 尺寸,不被压缩) =====
      this.PreviewArea()

      // ===== 2. 顶部工具栏 =====
      this.TopToolbar()

      // ===== 3. 右侧快捷工具栏(仅普通模式) =====
      if (this.viewerMode === ViewerMode.Normal) {
        this.QuickToolbar()
      }

      // ===== 4. 底部控制抽屉(仅普通模式,覆盖在预览上) =====
      if (this.viewerMode === ViewerMode.Normal) {
        this.BottomDrawer()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
    .onAreaChange((_old: Area, newArea: Area) => {
      const rawH: Length = newArea.height;
      let h: number = 0;
      if (typeof rawH === 'number') {
        h = rawH;
      }
      this.pageHeight = h;
      this.previewHeight = h;
      // Phase 1B:主动通知 Web 端 Viewer 尺寸变化(配合 ResizeObserver 兜底)
      const rawW: Length = newArea.width;
      let w: number = 0;
      if (typeof rawW === 'number') {
        w = rawW;
      }
      if (w > 0 && h > 0 && this.viewerState === ArkWebViewerState.READY) {
        this.arkWebController.resizeViewer(w, h);
      }
    })
  }

  /** 全屏预览区域(Web 组件渲染 Viewer) */
  @Builder
  PreviewArea() {
    Stack() {
      // Web 组件加载 rawfile/vrmviewer/index.html
      // controller 由 ArkWebVrmViewerController 提供
      Web({
        src: $rawfile(ArkWebViewerConfig.VIEWER_PAGE_PATH),
        controller: this.arkWebController.getWebviewController()
      })
        .width('100%')
        .height('100%')
        .backgroundColor('#222222')
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .fileAccess(true)
        .onControllerAttached(() => {
          this.arkWebController.onControllerAttached();
        })
        .onPageEnd(() => {
          this.webLoaded = true;
          this.arkWebController.onPageEnd();
        })
        .onPageBegin((_e) => {
          // 页面开始加载
        })
        .onErrorReceive((_e) => {
          this.lastErrorCode = 'WEB_LOAD_FAILED';
          this.lastError = 'Web 页面加载失败';
          this.viewerState = ArkWebViewerState.FAILED;
        })
        // Phase 1D-2A:资源请求拦截
        // 拦截 ark-tavern.local 资源请求,通过 FD 返回缓存文件内容
        // 其他请求返回 null(放行,交由 Web 默认处理)
        .onInterceptRequest((event: OnInterceptRequestEvent) => {
          if (this.resourceProvider === null) {
            return null;
          }
          const request: WebResourceRequest = event.request;
          const url: string = request.getRequestUrl();
          // 仅处理当前注册资源的 URL,其他一律放行
          if (!this.resourceProvider.matchesRequest(url)) {
            return null;
          }
          const requestHeaders: Array<Header> = request.getRequestHeader();
          const method: string = request.getRequestMethod();
          const result = this.resourceProvider.handleRequest(url, method, requestHeaders);
          if (result.response === null) {
            // 资源处理失败但不应阻塞 Web,放行让 Web 自行处理(通常 404)
            console.warn(`[VrmViewerPage] resource handleRequest returned null: ${result.errorCode} ${result.errorMessage}`);
            return null;
          }
          return result.response;
        })

      // 错误覆盖层(FAILED 状态)
      if (this.viewerState === ArkWebViewerState.FAILED) {
        Column() {
          Text('加载失败')
            .fontSize($r('app.float.app_font_subtitle'))
            .fontWeight(FontWeight.Bold)
            .fontColor('#FF6B6B')
            .margin({ bottom: 8 })
          Text(this.lastError || this.viewerDetail)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor('#BFFFFFFF')
            .textAlign(TextAlign.Center)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor('#CC000000')
      }
    }
    .width('100%')
    .height('100%')
    .align(Alignment.Center)
  }

  /** 顶部工具栏(透明覆盖层,内容顶部对齐,空白区点击穿透) */
  @Builder
  TopToolbar() {
    Column() {
      Row() {
        // 返回
        SymbolGlyph($r('sys.symbol.chevron_left'))
          .fontSize(24)
          .fontColor(['#FFFFFF'])
          .padding(8)
          .onClick(() => {
            router.back();
          })

        // 当前模型名称
        Text(this.modelDisplayName())
          .fontSize($r('app.float.app_font_body'))
          .fontColor('#FFFFFF')
          .fontWeight(FontWeight.Medium)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .padding({ left: 8, right: 8 })

        // 普通 / 演示模式
        Button(this.viewerMode === ViewerMode.Presentation ? '退出演示' : '演示模式')
          .fontSize($r('app.float.app_font_caption'))
          .fontColor('#FFFFFF')
          .backgroundColor('#33FFFFFF')
          .borderRadius($r('app.float.app_radius_sm'))
          .height(32)
          .padding({ left: 12, right: 12 })
          .onClick(() => {
            this.viewerMode = this.viewerMode === ViewerMode.Normal
              ? ViewerMode.Presentation : ViewerMode.Normal;
          })

        // 更多
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(24)
          .fontColor(['#FFFFFF'])
          .padding(8)
          .margin({ left: 4 })
          .onClick(() => {
            this.showPlaceholderToast();
          })
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_12'),
        right: $r('app.float.app_spacing_12'),
        top: this.statusBarHeight + 8,
        bottom: $r('app.float.app_spacing_8')
      })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 右侧快捷工具栏(透明覆盖层,内容右侧居中,空白区点击穿透) */
  @Builder
  QuickToolbar() {
    Row() {
      Column() {
        this.QuickButton('聚焦', () => { this.onFocusButton(); })
        this.QuickButton('重置', () => { this.onResetButton(); })
        this.QuickButton('截图', () => { this.showPlaceholderToast(); })
        this.QuickButton('设置', () => { this.showPlaceholderToast(); })
      }
      .backgroundColor('#99000000')
      .borderRadius($r('app.float.app_radius_md'))
      .padding($r('app.float.app_spacing_8'))
      .margin({ right: $r('app.float.app_spacing_16') })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(VerticalAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  @Builder
  QuickButton(label: string, action: () => void) {
    Text(label)
      .fontSize($r('app.float.app_font_caption'))
      .fontColor('#FFFFFF')
      .textAlign(TextAlign.Center)
      .width(44)
      .height(44)
      .borderRadius($r('app.float.app_radius_sm'))
      .margin({ top: 4, bottom: 4 })
      .onClick(() => {
        action();
      })
  }

  /** 底部控制抽屉(透明覆盖层,抽屉面板底部对齐,空白区点击穿透) */
  @Builder
  BottomDrawer() {
    Column() {
      // 抽屉面板(固定高度,不透明背景)
      Column() {
        // 拖动条 + 标题(点击切换状态)
        Column() {
          // 拖动条
          Row() {
            Divider()
              .color('#B0B0B0')
              .strokeWidth(3)
              .width(40)
              .borderRadius(2)
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .padding({ top: 8, bottom: 4 })

          // 标题行
          Row() {
            Text('控制面板')
              .fontSize($r('app.float.app_font_subtitle'))
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.app_text_primary'))
              .layoutWeight(1)

            // 三态指示
            Row() {
              this.StateDot(DrawerState.Collapsed)
              this.StateDot(DrawerState.Half)
              this.StateDot(DrawerState.Expanded)
            }
            .margin({ left: 8 })

            Text(this.drawerStateLabel())
              .fontSize($r('app.float.app_font_caption'))
              .fontColor($r('app.color.app_text_tertiary'))
              .margin({ left: 8 })
          }
          .width('100%')
          .padding({
            left: $r('app.float.app_spacing_16'),
            right: $r('app.float.app_spacing_16'),
            bottom: $r('app.float.app_spacing_8')
          })
          .alignItems(VerticalAlign.Center)
        }
        .width('100%')
        .onClick(() => {
          this.cycleDrawerState();
        })

        // Tab 栏 + 内容(仅 half / expanded 显示)
        if (this.drawerState !== DrawerState.Collapsed) {
          this.TabBar()
          this.TabContentArea()
        }
      }
      .width('100%')
      .height(this.getDrawerHeight())
      .backgroundColor($r('app.color.app_surface_1'))
      .borderRadius({ topLeft: $r('app.float.app_radius_lg'), topRight: $r('app.float.app_radius_lg') })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 抽屉三态指示点 */
  @Builder
  StateDot(state: DrawerState) {
    Stack()
      .width(8)
      .height(8)
      .borderRadius(4)
      .backgroundColor(this.drawerState === state
        ? $r('app.color.app_accent')
        : $r('app.color.app_divider'))
      .margin({ left: 4, right: 4 })
  }

  /** Tab 栏(水平可滚动) */
  @Builder
  TabBar() {
    Scroll() {
      Row() {
        this.TabItem('模型', ViewerTab.Model)
        this.TabItem('姿势', ViewerTab.Pose)
        this.TabItem('动画', ViewerTab.Animation)
        this.TabItem('表情', ViewerTab.Expression)
        this.TabItem('物理', ViewerTab.Physics)
        this.TabItem('场景', ViewerTab.Scene)
        this.TabItem('调试', ViewerTab.Debug)
      }
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16')
      })
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .height(40)
  }

  @Builder
  TabItem(label: string, tab: ViewerTab) {
    Text(label)
      .fontSize($r('app.float.app_font_body'))
      .fontColor(this.activeTab === tab
        ? $r('app.color.app_accent')
        : $r('app.color.app_text_secondary'))
      .fontWeight(this.activeTab === tab ? FontWeight.Medium : FontWeight.Normal)
      .padding({
        left: $r('app.float.app_spacing_12'),
        right: $r('app.float.app_spacing_12'),
        top: $r('app.float.app_spacing_8'),
        bottom: $r('app.float.app_spacing_8')
      })
      .onClick(() => {
        this.activeTab = tab;
      })
  }

  /** Tab 内容区(可滚动) */
  @Builder
  TabContentArea() {
    Scroll() {
      Column() {
        if (this.activeTab === ViewerTab.Model) {
          this.TabModelContent()
        } else if (this.activeTab === ViewerTab.Pose) {
          this.TabPoseContent()
        } else if (this.activeTab === ViewerTab.Animation) {
          this.TabAnimationContent()
        } else if (this.activeTab === ViewerTab.Expression) {
          this.TabExpressionContent()
        } else if (this.activeTab === ViewerTab.Physics) {
          this.TabPhysicsContent()
        } else if (this.activeTab === ViewerTab.Scene) {
          this.TabSceneContent()
        } else {
          this.TabDebugContent()
        }
      }
      .width('100%')
      .padding({
        left: $r('app.float.app_spacing_16'),
        right: $r('app.float.app_spacing_16'),
        top: $r('app.float.app_spacing_12'),
        bottom: this.navigationBarHeight + 24
      })
    }
    .layoutWeight(1)
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .width('100%')
  }

  // ===== 各 Tab 占位内容 =====

  @Builder
  TabModelContent() {
    Column() {
      // ===== Viewer 状态(只读) =====
      Text(`Viewer 状态: ${this.viewerState}`)
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_secondary'))
      Text(`详情: ${this.viewerDetail}`)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ top: 4 })

      Divider().margin({ top: 12, bottom: 12 })

      // ===== Phase 1D-1: 模型导入 =====
      Text('模型导入')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      // 导入按钮 + 清除按钮
      Row() {
        Button(this.importInProgress ? '导入中...' : '导入模型')
          .fontSize($r('app.float.app_font_body'))
          .fontColor('#FFFFFF')
          .backgroundColor($r('app.color.app_accent'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .layoutWeight(1)
          .enabled(!this.importInProgress && this.importState !== ModelImportState.DISPOSED && !this.loadInProgress)
          .onClick(() => {
            this.onImportModelButton();
          })

        Button('清除缓存')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .backgroundColor($r('app.color.app_surface_2'))
          .borderRadius($r('app.float.app_radius_sm'))
          .height(40)
          .margin({ left: 8 })
          .enabled(this.importedFile !== null && !this.importInProgress && !this.loadInProgress)
          .onClick(() => {
            this.onClearImportButton();
          })
      }
      .width('100%')

      // ===== 导入状态显示 =====
      Column() {
        this.ImportInfoRow('导入状态', this.importStateLabel())
        if (this.importedFile !== null) {
          this.ImportInfoRow('文件名', this.importedFile.displayName)
          this.ImportInfoRow('格式', this.formatLabel(this.importedFile))
          this.ImportInfoRow('文件大小', this.sizeLabel(this.importedFile.size))
          this.ImportInfoRow('缓存准备', this.cacheReadyLabel())
          this.ImportInfoRow('glTF 依赖', this.gltfDependencyLabel(this.importedFile))
        }
        if (this.importLastError.length > 0) {
          Text(`错误: ${this.importLastError}`)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 8 })
            .width('100%')
        }
      }
      .width('100%')
      .margin({ top: 12 })

      // ===== Phase 1D-2A: 资源暴露状态 =====
      Divider().margin({ top: 12, bottom: 12 })

      Text('资源暴露(Phase 1D-2A)')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      Column() {
        this.ImportInfoRow('资源状态', this.resourceStateLabel())
        if (this.preparedResource !== null) {
          this.ImportInfoRow('资源 URL', this.preparedResource.resourceUrl)
          this.ImportInfoRow('MIME', this.preparedResource.mimeType)
          this.ImportInfoRow('资源大小', this.sizeLabel(this.preparedResource.size))
          this.ImportInfoRow('扩展名', this.preparedResource.extension)
        }
        if (this.resourceLastError.length > 0) {
          Text(`资源错误: ${this.resourceLastError}`)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 8 })
            .width('100%')
        }
      }
      .width('100%')
      .margin({ top: 12 })

      // ===== Phase 1D-2B-1: 资源探测(HEAD 请求校验) =====
      Divider().margin({ top: 12, bottom: 12 })

      Text('资源探测(Phase 1D-2B-1)')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      // 验证资源按钮
      Button(this.probeInProgress ? '探测中...' : '验证资源')
        .fontSize($r('app.float.app_font_body'))
        .fontColor('#FFFFFF')
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .width('100%')
        .enabled(
          this.preparedResource !== null &&
          this.viewerState === ArkWebViewerState.READY &&
          !this.probeInProgress &&
          this.resourceState === ModelResourceState.READY &&
          !this.loadInProgress
        )
        .onClick(() => {
          this.onProbeResourceButton();
        })

      // 探测结果信息
      Column() {
        this.ImportInfoRow('探测状态', this.probeStateLabel())
        if (this.probeState !== ModelResourceProbeState.NOT_PROBED) {
          this.ImportInfoRow('HTTP 状态', this.probeStatusCode > 0 ? `${this.probeStatusCode}` : '—')
          this.ImportInfoRow('MIME 校验', this.probeMimeType.length > 0 ? this.probeMimeType : '—')
          this.ImportInfoRow('文件大小', this.probeContentLength >= 0 ? this.sizeLabel(this.probeContentLength) : '—')
          this.ImportInfoRow('资源 ID', this.probeResourceId.length > 0 ? this.probeResourceId : '—')
          this.ImportInfoRow('重定向', this.probeRedirected ? '是(异常)' : '否')
          this.ImportInfoRow('验证时间', this.probeVerifiedAtLabel())
        }
        if (this.probeErrorCode.length > 0) {
          Text(`错误码: ${this.probeErrorCode}`)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 8 })
            .width('100%')
          Text(`错误信息: ${this.probeErrorMessage}`)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 4 })
            .width('100%')
        }
        if (this.probeState === ModelResourceProbeState.VERIFIED) {
          Text('资源传输验证通过')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.model_settings_success'))
            .margin({ top: 8 })
            .width('100%')
        }
      }
      .width('100%')
      .margin({ top: 12 })

      // ===== Phase 1D-2B-2: 用户模型加载(GLTFLoader 实际加载与原子替换) =====
      Divider().margin({ top: 12, bottom: 12 })

      Text('用户模型加载(Phase 1D-2B-2)')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      // 加载模型按钮
      Button(this.loadInProgress ? '加载中...' : '加载模型')
        .fontSize($r('app.float.app_font_body'))
        .fontColor('#FFFFFF')
        .backgroundColor($r('app.color.app_accent'))
        .borderRadius($r('app.float.app_radius_sm'))
        .height(40)
        .width('100%')
        .enabled(
          this.preparedResource !== null &&
          this.viewerState === ArkWebViewerState.READY &&
          this.probeState === ModelResourceProbeState.VERIFIED &&
          !this.loadInProgress &&
          !this.probeInProgress
        )
        .onClick(() => {
          this.onLoadModelButton();
        })

      // 加载结果信息
      Column() {
        this.ImportInfoRow('加载状态', this.loadStateLabel())
        if (this.loadState !== 'NOT_REQUESTED') {
          this.ImportInfoRow('目标文件', this.loadDisplayName.length > 0 ? this.loadDisplayName : '—')
          this.ImportInfoRow('当前模型', this.loadModelDisplayName.length > 0 ? this.loadModelDisplayName : '—')
          this.ImportInfoRow('开始时间', this.loadStartedAtLabel())
          this.ImportInfoRow('完成时间', this.loadCompletedAtLabel())
        }
        if (this.loadErrorCode.length > 0) {
          Text(`错误码: ${this.loadErrorCode}`)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 8 })
            .width('100%')
          Text(`错误信息: ${this.loadErrorMessage}`)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 4 })
            .width('100%')
        }
        if (this.loadState === 'READY') {
          Text('用户模型加载成功,已替换当前模型')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.model_settings_success'))
            .margin({ top: 8 })
            .width('100%')
        }
        if (this.loadState === 'FAILED') {
          Text('加载失败,当前模型已保留,可重试')
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_danger'))
            .margin({ top: 8 })
            .width('100%')
        }
      }
      .width('100%')
      .margin({ top: 12 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 导入状态显示标签 */
  private importStateLabel(): string {
    if (this.importState === ModelImportState.IDLE) {
      return '空闲';
    } else if (this.importState === ModelImportState.PICKING) {
      return '正在选择文件...';
    } else if (this.importState === ModelImportState.COPYING) {
      return '正在复制到缓存...';
    } else if (this.importState === ModelImportState.READY) {
      return '已准备';
    } else if (this.importState === ModelImportState.CANCELLED) {
      return '已取消选择';
    } else if (this.importState === ModelImportState.FAILED) {
      return '导入失败';
    } else if (this.importState === ModelImportState.DISPOSED) {
      return '已销毁';
    }
    return '未知';
  }

  /** 格式标签(显示扩展名 + 文件类型 + MIME) */
  private formatLabel(file: ImportedModelFile): string {
    return `.${file.extension} (${file.fileType}, ${file.mimeType})`;
  }

  /** 文件大小标签(人类可读) */
  private sizeLabel(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    } else if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    } else {
      return `${(bytes / (1024 * 1024)).toFixed(2)} MB`;
    }
  }

  /** 缓存准备状态标签 */
  private cacheReadyLabel(): string {
    if (this.importState === ModelImportState.READY && this.importedFile !== null) {
      return '已写入受控缓存';
    }
    return '未准备';
  }

  /** glTF 依赖状态标签 */
  private gltfDependencyLabel(file: ImportedModelFile): string {
    if (file.gltfDependencyState === GltfDependencyState.NOT_APPLICABLE) {
      return '不适用(自包含二进制)';
    } else if (file.gltfDependencyState === GltfDependencyState.SELF_CONTAINED) {
      return '自包含(data: URI 内嵌)';
    } else if (file.gltfDependencyState === GltfDependencyState.EXTERNAL_FILES_REQUIRED) {
      return `依赖外部文件(${file.gltfExternalUris.length} 个),后续阶段需要附属资源导入`;
    } else if (file.gltfDependencyState === GltfDependencyState.REMOTE_RESOURCES_FOUND) {
      return `引用远程资源(${file.gltfExternalUris.length} 个),后续阶段需要网络下载策略`;
    } else if (file.gltfDependencyState === GltfDependencyState.INVALID_JSON) {
      return 'JSON 无效';
    }
    return '未知';
  }

  /** Phase 1D-2A: 资源 Provider 状态显示标签 */
  private resourceStateLabel(): string {
    if (this.resourceState === ModelResourceState.EMPTY) {
      return '空闲(无资源)';
    } else if (this.resourceState === ModelResourceState.READY) {
      return '已就绪(可拦截请求)';
    } else if (this.resourceState === ModelResourceState.DISPOSED) {
      return '已销毁';
    }
    return '未知';
  }

  @Builder
  ImportInfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .width(80)
      Text(value)
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_primary'))
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ top: 4, bottom: 4 })
  }

  @Builder
  TabPoseContent() {
    Column() {
      Text('等待 3D 模型与 Humanoid 初始化')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ bottom: 12 })

      Row() {
        this.DisabledPoseButton('Reset')
        this.DisabledPoseButton('Head Yaw Left')
        this.DisabledPoseButton('Head Yaw Right')
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  DisabledPoseButton(label: string) {
    Button(label)
      .fontSize($r('app.float.app_font_caption'))
      .fontColor($r('app.color.app_text_tertiary'))
      .backgroundColor($r('app.color.app_surface_2'))
      .borderRadius($r('app.float.app_radius_sm'))
      .height(36)
      .enabled(false)
      .layoutWeight(1)
      .margin({ left: 4, right: 4 })
  }

  @Builder
  TabAnimationContent() {
    Text('动画功能尚未启用')
      .fontSize($r('app.float.app_font_body'))
      .fontColor($r('app.color.app_text_secondary'))
      .width('100%')
  }

  @Builder
  TabExpressionContent() {
    Text('表情功能尚未启用')
      .fontSize($r('app.float.app_font_body'))
      .fontColor($r('app.color.app_text_secondary'))
      .width('100%')
  }

  @Builder
  TabPhysicsContent() {
    Text('Spring Bone 功能尚未启用')
      .fontSize($r('app.float.app_font_body'))
      .fontColor($r('app.color.app_text_secondary'))
      .width('100%')
  }

  @Builder
  TabSceneContent() {
    Column() {
      // 背景颜色选项
      Text('背景颜色')
        .fontSize($r('app.float.app_font_subtitle'))
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.app_text_primary'))
        .margin({ bottom: 8 })

      Row() {
        this.ColorSwatch('#1A1A1A')
        this.ColorSwatch('#2C3E50')
        this.ColorSwatch('#1B5E20')
        this.ColorSwatch('#4A148C')
        this.ColorSwatch('#F5F5F5')
      }
      .width('100%')
      .margin({ bottom: 16 })

      // 网格显示开关
      Row() {
        Text('网格显示')
          .fontSize($r('app.float.app_font_body'))
          .fontColor($r('app.color.app_text_primary'))
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.showGrid })
          .onChange((on: boolean) => {
            this.showGrid = on;
          })
      }
      .width('100%')
      .padding({
        top: $r('app.float.app_spacing_12'),
        bottom: $r('app.float.app_spacing_12')
      })
      .margin({ bottom: 16 })

      // 灯光强度滑块
      Column() {
        Row() {
          Text('灯光强度')
            .fontSize($r('app.float.app_font_body'))
            .fontColor($r('app.color.app_text_primary'))
            .layoutWeight(1)
          Text(`${this.lightIntensity}%`)
            .fontSize($r('app.float.app_font_caption'))
            .fontColor($r('app.color.app_text_tertiary'))
        }
        .width('100%')
        .margin({ bottom: 8 })

        Slider({ value: this.lightIntensity, min: 0, max: 100, style: SliderStyle.OutSet })
          .width('100%')
          .onChange((value: number) => {
            this.lightIntensity = Math.round(value);
          })
      }
      .width('100%')

      Text('本阶段控件仅保存页面状态,不驱动 3D')
        .fontSize($r('app.float.app_font_caption'))
        .fontColor($r('app.color.app_text_tertiary'))
        .margin({ top: 16 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  ColorSwatch(color: string) {
    Stack() {
      if (this.backgroundOption === color) {
        Text('✓')
          .fontSize(14)
          .fontColor(color === '#F5F5F5' ? '#1A1A1A' : '#FFFFFF')
      }
    }
    .width(36)
    .height(36)
    .borderRadius($r('app.float.app_radius_sm'))
    .backgroundColor(color)
    .border({
      width: this.backgroundOption === color ? 2 : 1,
      color: this.backgroundOption === color
        ? $r('app.color.app_accent')
        : $r('app.color.app_divider')
    })
    .margin({ right: 8 })
    .onClick(() => {
      this.backgroundOption = color;
    })
  }

  @Builder
  TabDebugContent() {
    Column() {
      this.DebugRow('Viewer UI', this.viewerState === ArkWebViewerState.READY ? 'READY' : this.viewerState)
      this.DebugRow('Web Bridge', this.webLoaded ? 'READY' : 'PENDING')
      this.DebugRow('Three.js', this.viewerState === ArkWebViewerState.READY ? 'READY' : 'NOT LOADED')
      this.DebugRow('Scene', this.viewerState === ArkWebViewerState.READY ? 'READY' : 'NOT INITIALIZED')
      this.DebugRow('Camera', this.viewerState === ArkWebViewerState.READY ? 'READY' : 'NOT INITIALIZED')
      this.DebugRow('Frame Loop', this.viewerState === ArkWebViewerState.READY ? 'RUNNING' : 'STOPPED')
      this.DebugRow('Model', 'NOT LOADED')
      this.DebugRow('Animation', 'NOT INITIALIZED')
      this.DebugRow('Humanoid', 'NOT INITIALIZED')
      this.DebugRow('Spring Bone', 'NOT INITIALIZED')
      this.DebugRow('Detail', this.viewerDetail)

      if (this.lastError.length > 0) {
        Text(`Error [${this.lastErrorCode}]: ${this.lastError}`)
          .fontSize($r('app.float.app_font_caption'))
          .fontColor($r('app.color.app_danger'))
          .margin({ top: 12 })
          .width('100%')
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  DebugRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize($r('app.float.app_font_body'))
        .fontColor($r('app.color.app_text_secondary'))
        .layoutWeight(1)
      Text(value)
        .fontSize($r('app.float.app_font_body'))
        .fontColor(value === 'READY'
          ? $r('app.color.model_settings_success')
          : (value === 'NOT IMPLEMENTED' || value === 'FAILED'
            ? $r('app.color.app_text_tertiary')
            : $r('app.color.app_text_primary')))
        .fontWeight(FontWeight.Medium)
    }
    .width('100%')
    .padding({
      top: $r('app.float.app_spacing_8'),
      bottom: $r('app.float.app_spacing_8')
    })
  }
}
