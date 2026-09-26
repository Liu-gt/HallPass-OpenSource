// ---------------------------------------------------------------------------
// backdrop：鸿蒙液态玻璃库的 ArkTS 出口。
//
// 真正的实现在 src/main/cpp（XComponent + EGL/GLES 自渲染 + native_drawing 文字），
// 这里把原生 NAPI 模块 `libbackdrop.so` 原样转出；使用者按名导入即可。
// ---------------------------------------------------------------------------

export {
  GlassGLBindNode,
  GlassGLUnbindNode,
  GlassGLSetNumber,
  GlassGLSetBool,
  GlassGLSetDebugMode,
  GlassGLSetPaused,
  GlassGLSetPhoto,
  GlassGLGetContentSurfaceId,
  GlassGLHasContentFrame,
  GlassGLSetContentBackdrop,
  GlassGLIsRunning,
  GlassGLRegisterMenuCallback,
  GlassGLUnregisterMenuCallback,
  GlassGLSetScene,
  GlassGLSetDensity,
  GlassGLSetBackdrop,
  GlassGLSetBackdropShift,
  // HallPass：镜像树偏移 / 主树偏移（纹理锁存补偿在原生侧算，见 GlassBandModel）
  GlassGLSetMirrorOffset,
  GlassGLSetContentOffset,
  GlassGLSetContentBand,
  GlassGLGetContentShift,
  GlassGLGetFrameMirrorOffset,
  GlassGLGetContentFrameCount,
  GlassGLSetOverlayMode,
  GlassGLSetDemoChrome,
  GlassGLSetTabs,
  GlassGLSetSelectedTab,
  GlassGLRegisterTabCallback,
  GlassGLUnregisterTabCallback,
  // HallPass：内联玻璃控件（开关 / 滑块）
  GlassGLWidgetConfigure,
  GlassGLWidgetSetState,
  GlassGLWidgetSetPress,
  GlassGLWidgetSetColors,
  GlassGLWidgetIsRunning,
  GlassGLWidgetDispose
} from 'libbackdrop.so';
