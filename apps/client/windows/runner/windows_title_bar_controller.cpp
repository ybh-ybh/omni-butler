#include "windows_title_bar_controller.h"

#include <flutter/standard_method_codec.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <windowsx.h>

#include <cstdint>
#include <utility>

namespace {

// 使用属性编号兼容未声明 Windows 11 精确颜色枚举的旧版 SDK。
constexpr DWORD kUseImmersiveDarkMode = 20;

// Windows 11 支持的标题栏背景属性。
constexpr DWORD kCaptionColor = 35;

// Windows 11 支持的标题栏文字属性。
constexpr DWORD kTextColor = 36;

// 自绘最大化按钮在正常消息回合读取窗口状态，连续点击也按顺序切换。
constexpr UINT kToggleMaximizeMessage = WM_APP + 0x321;

// 安全读取 Dart 标准编解码器的两种整数表示。
bool ReadInteger(const flutter::EncodableMap& arguments, const char* key,
                 int64_t& output) {
  // 当前参数的映射条目。
  const auto entry = arguments.find(flutter::EncodableValue(key));
  if (entry == arguments.end()) return false;
  // 较小整数使用的 32 位表示。
  if (const auto value = std::get_if<int32_t>(&entry->second)) {
    output = *value;
    return true;
  }
  // 原生窗口句柄使用的 64 位表示。
  if (const auto value = std::get_if<int64_t>(&entry->second)) {
    output = *value;
    return true;
  }
  return false;
}

}  // namespace

// 创建独立通道，在引擎启动前完成注册。
WindowsTitleBarController::WindowsTitleBarController(
    flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "omni/windows_title_bar",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

// 先取消方法回调，再清除仍存活窗口的原生钩子。
WindowsTitleBarController::~WindowsTitleBarController() {
  channel_->SetMethodCallHandler(nullptr);
  DetachWindow();
}

// 只接受本进程、当前消息线程上的有效窗口和完整颜色参数。
void WindowsTitleBarController::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "minimize" || call.method_name() == "toggleMaximize") {
    HandleWindowCommand(call, std::move(result));
    return;
  }
  if (call.method_name() != "applyTheme") {
    result->NotImplemented();
    return;
  }
  // Dart 传入的参数映射。
  const auto* arguments = call.arguments()
                              ? std::get_if<flutter::EncodableMap>(call.arguments())
                              : nullptr;
  // 待验证的主窗口地址。
  int64_t handle = 0;
  // 待验证的背景 COLORREF。
  int64_t background = 0;
  // 待验证的文字 COLORREF。
  int64_t foreground = 0;
  // 自绘标题栏的逻辑像素高度。
  int64_t caption_height = 0;
  // 自绘标题栏右侧三个按钮的逻辑像素总宽度。
  int64_t caption_buttons_width = 0;
  if (!arguments || !ReadInteger(*arguments, "windowHandle", handle) ||
      !ReadInteger(*arguments, "background", background) ||
      !ReadInteger(*arguments, "foreground", foreground) ||
      !ReadInteger(*arguments, "captionHeight", caption_height) ||
      !ReadInteger(*arguments, "captionButtonsWidth", caption_buttons_width) ||
      handle == 0 || caption_height <= 0 || caption_height >= 512 ||
      caption_buttons_width <= 0 || caption_buttons_width >= 512 ||
      background < 0 || background > 0x00ffffff || foreground < 0 ||
      foreground > 0x00ffffff) {
    result->Error("invalid_theme", "标题栏主题参数无效");
    return;
  }
  // 明暗参数必须使用布尔值，不能将其他类型隐式转换。
  const auto dark_entry = arguments->find(flutter::EncodableValue("dark"));
  if (dark_entry == arguments->end() ||
      !std::holds_alternative<bool>(dark_entry->second)) {
    result->Error("invalid_theme", "标题栏明暗参数无效");
    return;
  }
  // 参数中的真实主窗口句柄。
  const HWND window = reinterpret_cast<HWND>(static_cast<intptr_t>(handle));
  // 用于拒绝跨进程窗口的进程标识。
  DWORD process_id = 0;
  // 子类化只能在拥有窗口的消息线程进行。
  const DWORD thread_id = ::GetWindowThreadProcessId(window, &process_id);
  if (!::IsWindow(window) || process_id != ::GetCurrentProcessId() ||
      thread_id != ::GetCurrentThreadId()) {
    result->Error("invalid_window", "标题栏目标不是当前进程消息线程的有效窗口");
    return;
  }
  if (!AttachWindow(window)) {
    result->Error("title_bar_hook_failed", "无法监听主窗口主题消息");
    return;
  }
  dark_ = std::get<bool>(dark_entry->second) ? TRUE : FALSE;
  background_ = static_cast<COLORREF>(background);
  foreground_ = static_cast<COLORREF>(foreground);
  caption_height_ = static_cast<int>(caption_height);
  caption_buttons_width_ = static_cast<int>(caption_buttons_width);
  // 精确颜色属性不被旧系统支持时由 Flutter 绘制同色标题栏。
  bool exact_colors_applied = false;
  if (FAILED(ApplySavedTheme(&exact_colors_applied))) {
    result->Error("title_bar_theme_failed", "无法应用主窗口标题栏明暗模式");
    return;
  }
  if (!SetCustomCaption(!exact_colors_applied)) {
    result->Error("title_bar_theme_failed", "无法切换主窗口标题栏绘制模式");
    return;
  }
  result->Success(flutter::EncodableValue(exact_colors_applied));
}

// 使用系统命令保留最大化动画和工作区规则，但不能在 Dart 按钮栈内执行。
void WindowsTitleBarController::HandleWindowCommand(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // 仅接收已绑定主窗口的地址，拒绝操作其他窗口或退出后迟到的请求。
  const auto* arguments = call.arguments()
                              ? std::get_if<flutter::EncodableMap>(call.arguments())
                              : nullptr;
  // 来自当前主窗口控制器的句柄地址。
  int64_t handle = 0;
  if (!arguments || !ReadInteger(*arguments, "windowHandle", handle) ||
      reinterpret_cast<HWND>(static_cast<intptr_t>(handle)) != window_ ||
      !::IsWindow(window_)) {
    result->Error("invalid_window", "窗口按钮目标不是当前主窗口");
    return;
  }
  // 最小化直接使用系统命令；切换操作在消费消息时才读取实际状态。
  const bool minimize = call.method_name() == "minimize";
  if (!::PostMessageW(window_, minimize ? WM_SYSCOMMAND : kToggleMaximizeMessage,
                      minimize ? SC_MINIMIZE : 0, 0)) {
    result->Error("window_command_failed", "无法提交窗口按钮命令");
    return;
  }
  result->Success();
}

// 每个控制器最多持有一个主窗口钩子。
bool WindowsTitleBarController::AttachWindow(HWND window) {
  if (window_ == window) return true;
  DetachWindow();
  if (!::SetWindowSubclass(window, WindowSubclassProc,
                           reinterpret_cast<UINT_PTR>(this),
                           reinterpret_cast<DWORD_PTR>(this))) {
    return false;
  }
  window_ = window;
  return true;
}

// 主动销毁控制器或切换目标时解除子类化。
void WindowsTitleBarController::DetachWindow() {
  if (window_ != nullptr) {
    SetCustomCaption(false);
    ::RemoveWindowSubclass(window_, WindowSubclassProc,
                           reinterpret_cast<UINT_PTR>(this));
    window_ = nullptr;
  }
  DetachContentWindow();
  custom_caption_ = false;
  original_style_ = 0;
}

// 精确颜色失败不回滚已经成功设置的原生明暗属性。
HRESULT WindowsTitleBarController::ApplySavedTheme(bool* exact_colors_applied) {
  if (exact_colors_applied != nullptr) *exact_colors_applied = false;
  if (applying_theme_) return S_FALSE;
  if (window_ == nullptr || !::IsWindow(window_)) return E_HANDLE;
  applying_theme_ = true;
  // 明暗模式必须先应用，以保证不支持颜色属性时仍有可靠回退。
  const HRESULT dark_result = ::DwmSetWindowAttribute(
      window_, kUseImmersiveDarkMode, &dark_, sizeof(dark_));
  if (SUCCEEDED(dark_result)) {
    // Windows 11 标题栏背景设置结果。
    const HRESULT background_result = ::DwmSetWindowAttribute(
        window_, kCaptionColor, &background_, sizeof(background_));
    // Windows 11 标题栏文字设置结果。
    const HRESULT foreground_result = ::DwmSetWindowAttribute(
        window_, kTextColor, &foreground_, sizeof(foreground_));
    if (exact_colors_applied != nullptr) {
      *exact_colors_applied =
          SUCCEEDED(background_result) && SUCCEEDED(foreground_result);
    }
  }
  applying_theme_ = false;
  return dark_result;
}

// 只在原生与自绘模式切换时更新窗口样式，系统主题消息不触发布局变化。
bool WindowsTitleBarController::SetCustomCaption(bool enabled) {
  if (window_ == nullptr || !::IsWindow(window_)) return false;
  if (enabled && !AttachContentWindow()) return false;
  if (custom_caption_ == enabled) {
    if (!enabled) DetachContentWindow();
    return true;
  }
  // 切换前的实际样式，失败时用于完整回滚。
  const LONG_PTR previous_style = ::GetWindowLongPtrW(window_, GWL_STYLE);
  // 自绘模式仅隐藏原生标题栏，保留缩放边框和系统窗口命令能力。
  const LONG_PTR next_style =
      enabled ? previous_style & ~static_cast<LONG_PTR>(WS_CAPTION)
              : (previous_style & ~static_cast<LONG_PTR>(WS_CAPTION)) |
                    original_style_;
  ::SetLastError(ERROR_SUCCESS);
  if (::SetWindowLongPtrW(window_, GWL_STYLE, next_style) == 0 &&
      ::GetLastError() != ERROR_SUCCESS) {
    if (!custom_caption_) DetachContentWindow();
    return false;
  }
  // 强制系统按新样式重算边框，不主动修改窗口位置、大小或激活状态。
  constexpr UINT frame_flags = SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE |
                               SWP_NOZORDER | SWP_NOACTIVATE;
  // FRAMECHANGED 会同步计算客户区；必须先让钩子使用新的边框模式。
  const bool previous_custom_caption = custom_caption_;
  custom_caption_ = enabled;
  if (!::SetWindowPos(window_, nullptr, 0, 0, 0, 0, frame_flags)) {
    custom_caption_ = previous_custom_caption;
    ::SetWindowLongPtrW(window_, GWL_STYLE, previous_style);
    ::SetWindowPos(window_, nullptr, 0, 0, 0, 0, frame_flags);
    if (!custom_caption_) DetachContentWindow();
    return false;
  }
  if (enabled) original_style_ = previous_style & WS_CAPTION;
  if (!enabled) DetachContentWindow();
  return true;
}

// 每次命中测试读取实际 DPI，跨显示器移动后不依赖 Dart 再提交尺寸。
LRESULT WindowsTitleBarController::HitTestCustomFrame(LPARAM lparam) const {
  // 有符号屏幕坐标兼容位于主显示器左侧或上方的显示器。
  POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
  // 当前客户区范围，原生缩放边框不属于此范围。
  RECT client{};
  if (!::ScreenToClient(window_, &point) || !::GetClientRect(window_, &client)) {
    return HTCLIENT;
  }
  // 当前窗口的每英寸物理像素数。
  const UINT window_dpi = ::GetDpiForWindow(window_);
  // 未取得 DPI 时以标准 96 DPI 作为兼容值。
  const int dpi = window_dpi == 0 ? 96 : static_cast<int>(window_dpi);
  // Flutter 标题栏对应的实际物理像素高度。
  const int caption_height = ::MulDiv(caption_height_, dpi, 96);
  // 右侧按钮对应的实际物理像素总宽度。
  const int buttons_width = ::MulDiv(caption_buttons_width_, dpi, 96);
  if (point.x < client.left || point.x >= client.right ||
      point.y < client.top || point.y >= client.bottom) {
    return HTCLIENT;
  }
  if (!::IsZoomed(window_)) {
    // 顶部客户区覆盖原生边框后，继续提供相同 DPI 下的缩放热区。
    const int frame_y = ::GetSystemMetricsForDpi(SM_CYSIZEFRAME, dpi) +
                        ::GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
    // 顶角在客户区内的延伸宽度，与系统边框保持同一尺度。
    const int frame_x = ::GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi) +
                        ::GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
    if (point.y < client.top + frame_y) {
      if (point.x < client.left + frame_x) return HTTOPLEFT;
      if (point.x >= client.right - frame_x) return HTTOPRIGHT;
      return HTTOP;
    }
  }
  return point.y < client.top + caption_height &&
                 point.x < client.right - buttons_width
             ? HTCAPTION
             : HTCLIENT;
}

// Flutter 子窗口默认命中客户区，必须为同线程主窗口显式让出拖动区域。
bool WindowsTitleBarController::AttachContentWindow() {
  if (::IsWindow(content_window_) && ::GetParent(content_window_) == window_) {
    return true;
  }
  DetachContentWindow();
  // 只接受当前主窗口直属的 Flutter 渲染视图。
  const HWND content = ::FindWindowExW(window_, nullptr, L"FLUTTERVIEW", nullptr);
  // 当前候选渲染视图的所属进程。
  DWORD process_id = 0;
  // 同线程命中穿透与子类化要求子窗口在当前消息线程创建。
  const DWORD thread_id = ::GetWindowThreadProcessId(content, &process_id);
  if (!::IsWindow(content) || ::GetParent(content) != window_ ||
      process_id != ::GetCurrentProcessId() ||
      thread_id != ::GetCurrentThreadId() ||
      !::SetWindowSubclass(content, ContentSubclassProc,
                           reinterpret_cast<UINT_PTR>(this),
                           reinterpret_cast<DWORD_PTR>(this))) {
    return false;
  }
  content_window_ = content;
  return true;
}

// 切回原生标题栏、换窗口或控制器销毁时移除视图钩子。
void WindowsTitleBarController::DetachContentWindow() {
  if (content_window_ != nullptr) {
    ::RemoveWindowSubclass(content_window_, ContentSubclassProc,
                           reinterpret_cast<UINT_PTR>(this));
    content_window_ = nullptr;
  }
}

// 让系统继续寻找同线程下层主窗口，由主窗口提供 HTCAPTION 默认交互。
LRESULT CALLBACK WindowsTitleBarController::ContentSubclassProc(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam,
    UINT_PTR subclass_id, DWORD_PTR reference) {
  // 子窗口钩子对应的标题栏控制器。
  auto* controller = reinterpret_cast<WindowsTitleBarController*>(reference);
  if (message == WM_NCDESTROY) {
    ::RemoveWindowSubclass(window, ContentSubclassProc, subclass_id);
    if (controller->content_window_ == window) {
      controller->content_window_ = nullptr;
    }
    return ::DefSubclassProc(window, message, wparam, lparam);
  }
  if (message == WM_WINDOWPOSCHANGING && controller->custom_caption_) {
    // 宿主 MoveWindow 会缩放子视图；禁止把旧尺寸帧拷到新表面。
    auto* position = reinterpret_cast<WINDOWPOS*>(lparam);
    if (!(position->flags & SWP_NOSIZE)) position->flags |= SWP_NOCOPYBITS;
  }
  // 保留子窗口原有边界和其他输入消息处理。
  const LRESULT result = ::DefSubclassProc(window, message, wparam, lparam);
  if (message == WM_NCHITTEST && result == HTCLIENT &&
      controller->content_window_ == window && controller->custom_caption_ &&
      ::GetParent(window) == controller->window_ &&
      controller->HitTestCustomFrame(lparam) != HTCLIENT) {
    return HTTRANSPARENT;
  }
  return result;
}

// 自绘模式接管边框绘制与最大化范围，其余消息保留引擎和系统处理。
LRESULT CALLBACK WindowsTitleBarController::WindowSubclassProc(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam,
    UINT_PTR subclass_id, DWORD_PTR reference) {
  // 安装钩子时保存的唯一控制器。
  auto* controller = reinterpret_cast<WindowsTitleBarController*>(reference);
  if (message == kToggleMaximizeMessage && controller->window_ == window) {
    // 此时 Dart 按钮回调已退出，允许引擎在 WM_SIZE 内处理新尺寸帧。
    return ::DefSubclassProc(window, WM_SYSCOMMAND,
                            ::IsZoomed(window) ? SC_RESTORE : SC_MAXIMIZE, 0);
  }
  if (message == WM_NCDESTROY) {
    ::RemoveWindowSubclass(window, WindowSubclassProc, subclass_id);
    if (controller->window_ == window) {
      controller->DetachContentWindow();
      controller->window_ = nullptr;
      controller->custom_caption_ = false;
      controller->original_style_ = 0;
    }
    return ::DefSubclassProc(window, message, wparam, lparam);
  }
  if (controller->custom_caption_ && message == WM_NCPAINT) {
    // 拖动循环不能再用 GDI 把旧的顶部缩放框画到 Flutter 标题栏上。
    // DWM 继续负责阴影和侧边框，不禁用系统合成或窗口动画。
    return 0;
  }
  if (controller->custom_caption_ && message == WM_NCACTIVATE &&
      !::IsIconic(window)) {
    // 更新原生活动状态，但禁止默认过程顺带重绘已由 Flutter 接管的顶框。
    return ::DefSubclassProc(window, message, wparam, -1);
  }
  if (message == WM_NCCALCSIZE && controller->custom_caption_) {
    // 最大化外框已限制为工作区，客户区直接填满，不再额外内缩边框。
    if (::IsZoomed(window)) return 0;
    // 窗口化时默认处理保留左右与底部边框。
    auto* client = wparam
                       ? &reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam)->rgrc[0]
                       : reinterpret_cast<RECT*>(lparam);
    // 默认计算前的顶部是外窗口顶部，不包含原生缩放条带的内缩。
    const LONG window_top = client->top;
    ::DefSubclassProc(window, message, wparam, lparam);
    if (!::IsIconic(window)) client->top = window_top;
    return 0;
  }
  if (message == WM_WINDOWPOSCHANGING && controller->custom_caption_) {
    // 最大化/还原时禁止按旧屏幕位置搬移旧客户区，保留引擎新帧等待链。
    auto* position = reinterpret_cast<WINDOWPOS*>(lparam);
    if (!(position->flags & SWP_NOSIZE)) position->flags |= SWP_NOCOPYBITS;
  }
  // 先允许 Flutter 和 Windows 完成原有的窗口消息处理。
  const LRESULT result = ::DefSubclassProc(window, message, wparam, lparam);
  if (message == WM_WINDOWPOSCHANGING && controller->custom_caption_ &&
      ::IsZoomed(window) && !::IsIconic(window)) {
    // Windows 可能在 MINMAXINFO 后补偿主副屏尺寸差，以最终目标位置校正。
    auto* position = reinterpret_cast<WINDOWPOS*>(lparam);
    // 仅改变层级或激活状态时不触发额外布局。
    constexpr UINT unchanged_geometry = SWP_NOMOVE | SWP_NOSIZE;
    // 缺省位置或尺寸沿用当前窗口，不能将未使用的 WINDOWPOS 字段当坐标。
    RECT current{};
    if ((position->flags & unchanged_geometry) != unchanged_geometry &&
        ::GetWindowRect(window, &current)) {
      // 跨屏定位必须查目标矩形所在屏幕，不能查移动前的 HWND 所在屏幕。
      const LONG target_x =
          position->flags & SWP_NOMOVE ? current.left : position->x;
      // 系统虚拟桌面允许负坐标与上下排列的显示器。
      const LONG target_y =
          position->flags & SWP_NOMOVE ? current.top : position->y;
      // 用最终移动请求选择目标显示器，不缓存屏幕尺寸或 DPI。
      const RECT target{
          target_x, target_y,
          target_x + (position->flags & SWP_NOSIZE
                          ? current.right - current.left : position->cx),
          target_y + (position->flags & SWP_NOSIZE
                          ? current.bottom - current.top : position->cy)};
      // 工作区来自当前系统设置，已扣除该显示器上的任务栏。
      MONITORINFO monitor{sizeof(MONITORINFO)};
      if (::GetMonitorInfoW(
              ::MonitorFromRect(&target, MONITOR_DEFAULTTONEAREST), &monitor)) {
        position->x = monitor.rcWork.left;
        position->y = monitor.rcWork.top;
        position->cx = monitor.rcWork.right - monitor.rcWork.left;
        position->cy = monitor.rcWork.bottom - monitor.rcWork.top;
        position->flags &= ~unchanged_geometry;
        position->flags |= SWP_NOCOPYBITS;
      }
    }
  }
  if (message == WM_GETMINMAXINFO && controller->custom_caption_) {
    // 默认过程保留 Flutter 的最小/最大拖拽约束，此处仅修正最大化范围。
    auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
    // 使用窗口所在屏幕的工作区，兼容任务栏放在任意边及副屏负坐标。
    MONITORINFO monitor{sizeof(MONITORINFO)};
    if (::GetMonitorInfoW(::MonitorFromWindow(window, MONITOR_DEFAULTTONEAREST),
                          &monitor)) {
      limits->ptMaxPosition.x = monitor.rcWork.left - monitor.rcMonitor.left;
      limits->ptMaxPosition.y = monitor.rcWork.top - monitor.rcMonitor.top;
      limits->ptMaxSize.x = monitor.rcWork.right - monitor.rcWork.left;
      limits->ptMaxSize.y = monitor.rcWork.bottom - monitor.rcWork.top;
    }
  }
  if (message == WM_NCHITTEST && result == HTCLIENT &&
      controller->window_ == window && controller->custom_caption_) {
    return controller->HitTestCustomFrame(lparam);
  }
  if ((message == WM_DWMCOLORIZATIONCOLORCHANGED || message == WM_THEMECHANGED ||
       message == WM_SETTINGCHANGE) &&
      controller->window_ == window && !controller->applying_theme_) {
    controller->ApplySavedTheme();
  }
  return result;
}
