#include "windows_tray_controller.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <strsafe.h>

#include <utility>

namespace {

// 托盘隐藏窗口类名。
constexpr wchar_t kTrayWindowClassName[] = L"OmniButlerTrayWindow";

// 托盘图标回调消息。
constexpr UINT kTrayCallbackMessage = WM_APP + 41;

// 托盘菜单命令标识。
constexpr UINT kOpenCommand = 41001;
constexpr UINT kToggleCommand = 41002;
constexpr UINT kExitCommand = 41003;

// 将 UTF-8 路径转换为 Windows UTF-16 路径。
std::wstring Utf16FromUtf8(const std::string& value) {
  if (value.empty()) {
    return std::wstring();
  }
  // 转换结果所需字符数。
  const int target_length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (target_length <= 0) {
    return std::wstring();
  }
  // UTF-16 转换结果。
  std::wstring result(target_length, L'\0');
  const int converted_length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), result.data(), target_length);
  return converted_length == target_length ? result : std::wstring();
}

}  // namespace

WindowsTrayController::WindowsTrayController(
    flutter::BinaryMessenger* messenger) {
  channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "omni/windows_tray",
          &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethodCall(call, std::move(result));
      });
  taskbar_created_message_ = ::RegisterWindowMessageW(L"TaskbarCreated");
}

WindowsTrayController::~WindowsTrayController() {
  DestroyTray();
  ::UnregisterClassW(kTrayWindowClassName, ::GetModuleHandleW(nullptr));
}

void WindowsTrayController::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (method_call.method_name() == "initialize") {
    // Dart 传入的初始化参数。
    const auto& arguments =
        std::get<flutter::EncodableMap>(*method_call.arguments());
    // 打包后托盘图标绝对路径。
    const auto& icon_path = std::get<std::string>(
        arguments.at(flutter::EncodableValue("iconPath")));
    // 悬浮窗菜单项初始勾选状态。
    const bool floating_enabled = std::get<bool>(
        arguments.at(flutter::EncodableValue("floatingEnabled")));
    if (!Initialize(icon_path, floating_enabled)) {
      result->Error("tray_initialize_failed", "无法创建 Windows 系统托盘");
      return;
    }
    result->Success();
    return;
  }
  if (method_call.method_name() == "setFloatingEnabled") {
    floating_enabled_ = std::get<bool>(*method_call.arguments());
    result->Success();
    return;
  }
  if (method_call.method_name() == "destroy") {
    DestroyTray();
    result->Success();
    return;
  }
  result->NotImplemented();
}

bool WindowsTrayController::Initialize(const std::string& icon_path,
                                       bool floating_enabled) {
  floating_enabled_ = floating_enabled;
  if (!EnsureMessageWindow()) {
    return false;
  }
  if (icon_ != nullptr) {
    ::DestroyIcon(icon_);
    icon_ = nullptr;
  }
  // Windows 可读取的托盘图标路径。
  const std::wstring windows_icon_path = Utf16FromUtf8(icon_path);
  icon_ = static_cast<HICON>(::LoadImageW(
      nullptr, windows_icon_path.c_str(), IMAGE_ICON,
      ::GetSystemMetrics(SM_CXSMICON), ::GetSystemMetrics(SM_CYSMICON),
      LR_LOADFROMFILE));
  return AddTrayIcon();
}

bool WindowsTrayController::EnsureMessageWindow() {
  if (message_window_ != nullptr) {
    return true;
  }
  // 托盘隐藏窗口类定义。
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = WindowsTrayController::WindowProc;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.lpszClassName = kTrayWindowClassName;
  if (::RegisterClassW(&window_class) == 0 &&
      ::GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    return false;
  }
  message_window_ = ::CreateWindowExW(
      WS_EX_TOOLWINDOW, kTrayWindowClassName, L"Omni Butler Tray",
      WS_OVERLAPPED, 0, 0, 0, 0, nullptr, nullptr,
      ::GetModuleHandleW(nullptr), this);
  return message_window_ != nullptr;
}

bool WindowsTrayController::AddTrayIcon() {
  if (message_window_ == nullptr || icon_ == nullptr) {
    return false;
  }
  if (tray_icon_added_) {
    ::Shell_NotifyIconW(NIM_DELETE, &notify_icon_data_);
    tray_icon_added_ = false;
  }
  ::ZeroMemory(&notify_icon_data_, sizeof(notify_icon_data_));
  notify_icon_data_.cbSize = sizeof(notify_icon_data_);
  notify_icon_data_.hWnd = message_window_;
  notify_icon_data_.uID = 1;
  notify_icon_data_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  notify_icon_data_.uCallbackMessage = kTrayCallbackMessage;
  notify_icon_data_.hIcon = icon_;
  ::StringCchCopyW(notify_icon_data_.szTip,
                   ARRAYSIZE(notify_icon_data_.szTip), L"Omni Butler");
  tray_icon_added_ =
      ::Shell_NotifyIconW(NIM_ADD, &notify_icon_data_) == TRUE;
  return tray_icon_added_;
}

void WindowsTrayController::ShowContextMenu() {
  // 本次右键展示的托盘菜单。
  HMENU menu = ::CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }
  ::AppendMenuW(menu, MF_STRING, kOpenCommand, L"打开主界面");
  // 悬浮窗菜单项状态。
  const UINT toggle_flags =
      MF_STRING | (floating_enabled_ ? MF_CHECKED : MF_UNCHECKED);
  ::AppendMenuW(menu, toggle_flags, kToggleCommand, L"显示桌面悬浮框");
  ::AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  ::AppendMenuW(menu, MF_STRING, kExitCommand, L"退出 Omni Butler");
  // 当前鼠标位置。
  POINT cursor_position{};
  ::GetCursorPos(&cursor_position);
  ::SetForegroundWindow(message_window_);
  ::TrackPopupMenu(menu, TPM_BOTTOMALIGN | TPM_LEFTALIGN | TPM_RIGHTBUTTON,
                   cursor_position.x, cursor_position.y, 0, message_window_,
                   nullptr);
  ::PostMessageW(message_window_, WM_NULL, 0, 0);
  ::DestroyMenu(menu);
}

void WindowsTrayController::SendEvent(const std::string& event_name) {
  channel_->InvokeMethod(
      "event", std::make_unique<flutter::EncodableValue>(event_name));
}

void WindowsTrayController::DestroyTray() {
  if (tray_icon_added_) {
    ::Shell_NotifyIconW(NIM_DELETE, &notify_icon_data_);
    tray_icon_added_ = false;
  }
  if (icon_ != nullptr) {
    ::DestroyIcon(icon_);
    icon_ = nullptr;
  }
  if (message_window_ != nullptr) {
    ::DestroyWindow(message_window_);
    message_window_ = nullptr;
  }
}

LRESULT CALLBACK WindowsTrayController::WindowProc(HWND window, UINT message,
                                                   WPARAM wparam,
                                                   LPARAM lparam) {
  // 当前隐藏窗口对应的托盘控制器。
  auto* controller = reinterpret_cast<WindowsTrayController*>(
      ::GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_NCCREATE) {
    // Windows 创建参数中的托盘控制器。
    const auto* create_struct = reinterpret_cast<CREATESTRUCTW*>(lparam);
    controller = static_cast<WindowsTrayController*>(
        create_struct->lpCreateParams);
    ::SetWindowLongPtrW(window, GWLP_USERDATA,
                        reinterpret_cast<LONG_PTR>(controller));
  }
  if (controller == nullptr) {
    return ::DefWindowProcW(window, message, wparam, lparam);
  }
  if (message == controller->taskbar_created_message_) {
    controller->tray_icon_added_ = false;
    controller->AddTrayIcon();
    return 0;
  }
  if (message == kTrayCallbackMessage) {
    if (lparam == WM_LBUTTONUP) {
      controller->SendEvent("open");
    } else if (lparam == WM_RBUTTONUP) {
      controller->ShowContextMenu();
    }
    return 0;
  }
  if (message == WM_COMMAND) {
    switch (LOWORD(wparam)) {
      case kOpenCommand:
        controller->SendEvent("open");
        break;
      case kToggleCommand:
        controller->SendEvent("toggle");
        break;
      case kExitCommand:
        controller->SendEvent("exit");
        break;
      default:
        break;
    }
    return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}
