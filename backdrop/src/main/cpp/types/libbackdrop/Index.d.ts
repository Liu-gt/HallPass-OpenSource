// ---------------------------------------------------------------------------
// GLES 自渲染（demo/entry/src/main/ets/pages/GlassPage.ets 用）
// ---------------------------------------------------------------------------

/** 把 XComponent 的 FrameNode 交给原生渲染器，建立 SurfaceHolder 绑定。 */
export const GlassGLBindNode: (id: string, node: FrameNode) => void

/** 解绑并停掉渲染线程。 */
export const GlassGLUnbindNode: (id: string) => void

/** 改一个数值参数。id 是全局参数编号，见 demo/entry/src/main/ets/pages/GlassPage.ets 的 NUMBER_SPECS。 */
export const GlassGLSetNumber: (id: number, value: number) => void

/** 改一个开关参数。id 是全局开关编号，见 demo/entry/src/main/ets/pages/GlassPage.ets 的 TOGGLE_SPECS。 */
export const GlassGLSetBool: (id: number, value: boolean) => void

/**
 * 切目录场景（见 demo/entry/src/main/ets/catalog/Scenes.ets 的 SceneId）。
 * 0 = 玻璃页签条（默认），其余为组件示例。
 */
export const GlassGLSetScene: (scene: number) => void

/** 上报显示密度（vp -> px），用于原生侧按 dp 排版。缺省 4。 */
export const GlassGLSetDensity: (density: number) => void

/** 消融/调试模式：0=正常，1=只画背景，2=只画折射，3=不画玻璃。 */
export const GlassGLSetDebugMode: (mode: number) => void

/**
 * 暂停/恢复绘制。页面不可见（被覆盖、进后台、切到别的 tab）时传 true：
 * 渲染线程停止出帧、也不再步进动画（surface 保留最后一帧），恢复时传 false。
 * 静止时库自己也会跳过绘制，这个接口用于"确定没人看"的场景。
 */
export const GlassGLSetPaused: (paused: boolean) => void

/**
 * ArkTS 实时内容纹理的 surfaceId（BuilderNode 纹理导出）。
 *
 * 拿到非空串后交给 `BuilderNode(uiContext, { type: NodeRenderType.RENDER_TYPE_TEXTURE,
 * surfaceId })`，ArkUI 就会把这棵组件树渲染进 GL 侧的外纹理（GPU 直达，不过 CPU）。
 * 返回空串表示渲染线程还没起来 / 未创建内容纹理，稍后重试。
 */
export const GlassGLGetContentSurfaceId: () => string

/** 内容纹理是否已经收到过帧（true 才可以把内容交给 GL 绘制）。 */
export const GlassGLHasContentFrame: () => boolean

/**
 * 把 ArkTS 内容纹理当背景：背景 pass 按 1:1 采样内容纹理，最终成帧先整屏铺它、
 * 再把页签条叠上去（叠加模式）。true 之前玻璃用 `GlassGLSetBackdrop` 的底图。
 */
export const GlassGLSetContentBackdrop: (on: boolean) => void

/** 传照片背景的裸 RGBA（前 8 字节 = u32 LE 宽、高）。 */
export const GlassGLSetPhoto: (data: ArrayBuffer) => void

/**
 * 传背景快照：RGBA8888、行 0 = 顶部、**无 8 字节头**。
 * `rowBytes` 是源图每行的字节数（PixelMap 的 getBytesNumberPerRow()，可能含对齐填充）。
 * 页签条玻璃的模糊 / 折射就是采样这张图（HallPass 用内容快照回填）。
 */
export const GlassGLSetBackdrop: (data: ArrayBuffer, width: number, height: number,
  rowBytes: number) => void

/**
 * 背景快照的平移（vp，正 = 内容上移 / 左移）：滚动时把页面滚动增量喂进来，
 * 玻璃里的快照背景按同样位移平移采样，与真实内容同帧（快照只做定期纠偏）。
 */
export const GlassGLSetBackdropShift: (dxVp: number, dyVp: number) => void

/**
 * 镜像树（BuilderNode 纹理导出）**逻辑上已应用**的滚动偏移（vp，正 = 内容上移）。
 *
 * 这个值只是"镜像该在哪"：离屏渲染出帧晚 1~2 帧，玻璃里当下真正装的是**出帧那一刻**
 * 的偏移。渲染线程在 OH_NativeImage 的出帧回调里把它锁存成"纹理偏移"，
 * ArkTS 用 `GlassGLGetFrameMirrorOffset()` 取锁存值算滞后补偿。
 *
 * @param resync 切页 / 重建这类**换内容**的时刻传 true：把纹理偏移也直接置成新值，
 *   否则补偿会拿上一页的偏移去算，得到一大截假的"越界平移"。
 */
export const GlassGLSetMirrorOffset: (offsetVp: number, resync?: boolean) => void

/**
 * 主树（ArkUI 直显）的视觉偏移（vp，正 = 内容上移）+ 一帧外推量（vp，可省）。
 *
 * 每次滚动上报推一次。**采样位移由渲染线程在画这一帧时算**（基准 = 手里那帧纹理
 * 的偏移），所以纹理换帧与补偿变化落在同一帧 —— 放在 ArkTS 侧算会差一拍，
 * 镜像重排量化落地时看起来就是"透过玻璃的内容在闪"。
 *
 * 外推量按 48ms 衰减，滚动停下后会自己归零，不需要调用方补发。
 */
export const GlassGLSetContentOffset: (offsetVp: number, leadVp?: number) => void

/** 当前实际使用的采样位移（vp，诊断用）。 */
export const GlassGLGetContentShift: () => number

/**
 * 镜像条带上下余量 + 采样位移预算（vp）：内容纹理比 GL 的条带 surface 高出的部分，
 * 让采样位移能直接吃掉下拉刷新 / 越界回弹的整段位移（当帧生效，不依赖镜像容器平移）。
 *
 * @param extraTopVp 条带上方余量（下拉方向，采样往纹理上沿）
 * @param extraBottomVp 条带下方余量（底部回弹方向，采样往纹理下沿）
 * @param shiftUpVp 负位移（下拉）预算，必须 ≤ 面板上留白 + extraTopVp
 * @param shiftDownVp 正位移（底部回弹）预算，必须 ≤ 面板下边距 + extraBottomVp
 */
export const GlassGLSetContentBand:
  (extraTopVp: number, extraBottomVp: number, shiftUpVp: number, shiftDownVp: number) => void

/** 当前纹理对应的镜像偏移（锁存值，vp，诊断用）。 */
export const GlassGLGetFrameMirrorOffset: () => number

/** 累计消费到的内容纹理帧数（诊断：确认镜像真的在出帧）。 */
export const GlassGLGetContentFrameCount: () => number

/**
 * 叠加模式：surface 透明，只画页签条本体（条外 alpha = 0 只留投影），
 * ArkUI 应用内容原样透出。HallPass 必须打开；demo 整屏场景保持关闭。
 */
export const GlassGLSetOverlayMode: (on: boolean) => void

/**
 * demo 专属件开关：false 时隐藏顶部三个玻璃按钮与可拖动浮动玻璃件，并禁用照片纵向滚动。
 * HallPass 传 false；demo 保持 true。
 */
export const GlassGLSetDemoChrome: (on: boolean) => void

/**
 * 配置页签文案 / 图标 / 颜色（正好 3 条）。
 * - labels：底部文案，如 ['保险库', '生成器', '设置']
 * - iconPaths：24×24 视口的 SVG path（只支持绝对 M/L/Q/Z），空字符串 = 不画图标
 * - selectedArgb / unselectedArgb：选中 / 未选中颜色（ARGB）
 */
export const GlassGLSetTabs: (labels: string[], iconPaths: string[], selectedArgb: number,
  unselectedArgb: number) => void

/** 外部同步选中页签（0..2）：指示器弹簧移动过去，并按新选中态重渲染文字。 */
export const GlassGLSetSelectedTab: (index: number) => void

/** 注册"页签被点击/拖动切换"的回调（index 0..2）。 */
export const GlassGLRegisterTabCallback: (callback: (index: number) => void) => void

/** 注销上面的回调（页面 aboutToDisappear 里调）。 */
export const GlassGLUnregisterTabCallback: () => void

/** 渲染线程是否在跑（排查用）。 */
export const GlassGLIsRunning: () => boolean

// ---------------------------------------------------------------------------
// HallPass：内联玻璃控件（开关 / 滑块）
//
// 一个控件 = 一个 XComponent（id 前缀 glassToggle / glassSlider），一个独立渲染
// 实例。控件背景是固定的卡片底色（只有深浅色会变），因此不传内容快照、按需渲染；
// 触摸 / 手势由覆盖在上层的 ArkUI Toggle / Slider 处理，这里只同步"画什么"。
// 组件实现见 entry 的 common/components/glass/GlassToggle.ets / GlassSlider.ets。
// ---------------------------------------------------------------------------

/** 绑定配置：id 必须以 glassToggle / glassSlider 开头；kind 0=开关 1=滑块；density = vp2px(1)。 */
export const GlassGLWidgetConfigure: (id: string, kind: number, density: number) => void

/** 同步状态：开关 0/1，滑块 0..1（动画由原生弹簧追随）。 */
export const GlassGLWidgetSetState: (id: string, value: number) => void

/** 同步按压 / 拖动（ArkUI 侧 Down / Up / Begin / End 上报）。 */
export const GlassGLWidgetSetPress: (id: string, pressed: boolean) => void

/** 主题强调色（ARGB）与所在卡片底色（ARGB）。 */
export const GlassGLWidgetSetColors: (id: string, accentArgb: number, backgroundArgb: number) => void

/** 渲染线程是否已起来（组件自检，false 时回退原生 ArkUI 控件）。 */
export const GlassGLWidgetIsRunning: (id: string) => boolean

/** 组件卸载时释放渲染实例（线程 / EGL / GL 资源）。 */
export const GlassGLWidgetDispose: (id: string) => void

/**
 * 注册"GL 里画的顶部三个玻璃按钮被点击"的回调。
 * target：0=底座，1=指示器·静止，2=指示器·拖动。
 * 页面消失前请调用 `GlassGLUnregisterMenuCallback`，否则回调会打到已销毁的页面上。
 */
export const GlassGLRegisterMenuCallback: (callback: (target: number) => void) => void

/** 注销上面的回调（页面 aboutToDisappear 里调）。 */
export const GlassGLUnregisterMenuCallback: () => void
