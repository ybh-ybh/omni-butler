#include "windows_floating_controller.h"

#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <commctrl.h>

#include <limits>
#include <utility>

namespace {
// 只在本次缩放栈中替换宿主对 Flutter 子视图的 MoveWindow 更新。
LRESULT CALLBACK ResizeWithoutCopying(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam, UINT_PTR subclass_id,
                                     DWORD_PTR reference) {
  if (message == WM_NCDESTROY) {
    ::RemoveWindowSubclass(window, ResizeWithoutCopying, subclass_id);
  }
  if (message == WM_SIZE) {
    // 当前宿主中唯一的 Flutter 渲染子窗口。
    const HWND content = reinterpret_cast<HWND>(reference);
    // 无边框宿主实际客户区，不能使用含系统边框的创建尺寸。
    RECT client{};
    if (::IsWindow(content) && ::GetParent(content) == window &&
        ::GetClientRect(window, &client) &&
        ::SetWindowPos(content, nullptr, client.left, client.top,
                       client.right - client.left, client.bottom - client.top,
                       SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                           SWP_NOCOPYBITS)) {
      // 与 Flutter 宿主的 WM_SIZE 行为相同，但不回拷旧尺寸的画面。
      return 0;
    }
  }
  return ::DefSubclassProc(window, message, wparam, lparam);
}

// 安全解码 Dart 通道的 32/64 位整数，拒绝无效参数。
bool ReadInteger(const flutter::EncodableMap& arguments, const char* key,
                 int64_t& output) {
  // 本次需要读取的参数条目。
  const auto entry = arguments.find(flutter::EncodableValue(key));
  if (entry == arguments.end()) return false;
  // 较小的 Dart 整数使用 32 位编码。
  if (const auto value = std::get_if<int32_t>(&entry->second)) {
    output = *value;
    return true;
  }
  // 窗口句柄及较大的 Dart 整数使用 64 位编码。
  if (const auto value = std::get_if<int64_t>(&entry->second)) {
    output = *value;
    return true;
  }
  return false;
}
}  // namespace

WindowsFloatingController::WindowsFloatingController(
    flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "omni/windows_floating",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
}

void WindowsFloatingController::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() != "setBounds") {
    result->NotImplemented();
    return;
  }
  // 本次原生尺寸更新的参数集合。
  const auto* arguments = call.arguments()
                              ? std::get_if<flutter::EncodableMap>(call.arguments())
                              : nullptr;
  // 本次请求的真实宿主句柄。
  int64_t handle = 0;
  // 本次请求的屏幕物理左坐标。
  int64_t left = 0;
  // 本次请求的屏幕物理顶坐标。
  int64_t top = 0;
  // 本次请求的物理宽度。
  int64_t width = 0;
  // 本次请求的物理高度。
  int64_t height = 0;
  if (!arguments || !ReadInteger(*arguments, "handle", handle) ||
      !ReadInteger(*arguments, "left", left) ||
      !ReadInteger(*arguments, "top", top) ||
      !ReadInteger(*arguments, "width", width) ||
      !ReadInteger(*arguments, "height", height) || width <= 0 || height <= 0 ||
      width > std::numeric_limits<int>::max() ||
      height > std::numeric_limits<int>::max() ||
      left < std::numeric_limits<int>::min() ||
      left > std::numeric_limits<int>::max() ||
      top < std::numeric_limits<int>::min() ||
      top > std::numeric_limits<int>::max()) {
    result->Error("invalid_bounds", "悬浮窗尺寸参数无效");
    return;
  }
  // 必须使用卡片自己的窗口，而不能操作跨进程桌面宿主。
  const HWND window = reinterpret_cast<HWND>(static_cast<intptr_t>(handle));
  // 当前窗口所属进程。
  DWORD process_id = 0;
  ::GetWindowThreadProcessId(window, &process_id);
  if (!::IsWindow(window) || process_id != ::GetCurrentProcessId()) {
    // 关闭窗口后迟到的请求直接丢弃。
    result->Success();
    return;
  }
  // 当前窗口的屏幕物理矩形。
  RECT current{};
  if (!::GetWindowRect(window, &current)) {
    result->Error("read_bounds_failed", "无法读取悬浮窗矩形");
    return;
  }
  // 保留位置或尺寸时不发送多余的移动/缩放消息。
  UINT flags = SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOOWNERZORDER;
  if (current.left == left && current.top == top) flags |= SWP_NOMOVE;
  if (current.right - current.left == width &&
      current.bottom - current.top == height) flags |= SWP_NOSIZE;
  if ((flags & SWP_NOMOVE) && (flags & SWP_NOSIZE)) {
    result->Success();
    return;
  }
  // 桌面子窗口需要将目标屏幕坐标转换到真实父窗口客户区。
  POINT position{static_cast<LONG>(left), static_cast<LONG>(top)};
  // 卡片当前的原生父窗口。
  const HWND parent = ::GetParent(window);
  if ((::GetWindowLongPtrW(window, GWL_STYLE) & WS_CHILD) && parent) {
    ::ScreenToClient(parent, &position);
  }
  // 只查找本次目标宿主中的实际渲染子窗口，不改其他窗口的消息处理。
  const HWND content = ::FindWindowExW(window, nullptr, L"FLUTTERVIEW", nullptr);
  // 仅真实缩放期间拦截内部视图的旧像素复制；纯移动不改变绘制流程。
  const bool resize_content = !(flags & SWP_NOSIZE) && content;
  if (resize_content &&
      !::SetWindowSubclass(window, ResizeWithoutCopying, 1,
                           reinterpret_cast<DWORD_PTR>(content))) {
    result->Error("resize_hook_failed", "无法同步悬浮窗内部视图");
    return;
  }
  if (!(flags & SWP_NOSIZE)) flags |= SWP_NOCOPYBITS;
  // 父子视图都禁用旧画面回拷，保留引擎等待新尺寸帧的同步机制。
  const BOOL updated = ::SetWindowPos(
      window, nullptr, position.x, position.y, static_cast<int>(width),
      static_cast<int>(height), flags);
  if (resize_content) {
    ::RemoveWindowSubclass(window, ResizeWithoutCopying, 1);
  }
  if (!updated) {
    result->Error("resize_failed", "无法更新悬浮窗尺寸");
    return;
  }
  result->Success();
}
