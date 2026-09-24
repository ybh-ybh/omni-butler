#ifndef RUNNER_WINDOWS_TRAY_CONTROLLER_H_
#define RUNNER_WINDOWS_TRAY_CONTROLLER_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <string>

// 管理不依赖隐式 Flutter View 的 Windows 系统托盘。
class WindowsTrayController {
 public:
  // 使用当前 Flutter 引擎消息通道创建托盘控制器。
  explicit WindowsTrayController(flutter::BinaryMessenger* messenger);
  ~WindowsTrayController();

  WindowsTrayController(const WindowsTrayController&) = delete;
  WindowsTrayController& operator=(const WindowsTrayController&) = delete;

 private:
  // 托盘消息使用的隐藏窗口过程。
  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);

  // 处理来自 Dart 的托盘方法调用。
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // 创建或更新托盘图标。
  bool Initialize(const std::string& icon_path, bool floating_enabled);

  // 创建托盘使用的隐藏消息窗口。
  bool EnsureMessageWindow();

  // 向任务栏通知区添加托盘图标。
  bool AddTrayIcon();

  // 在鼠标位置打开托盘菜单。
  void ShowContextMenu();

  // 向 Dart 发送托盘操作事件。
  void SendEvent(const std::string& event_name);

  // 销毁托盘图标和隐藏窗口。
  void DestroyTray();

  // Flutter 方法通道。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  // 托盘使用的隐藏顶层窗口。
  HWND message_window_ = nullptr;

  // 当前托盘通知数据。
  NOTIFYICONDATAW notify_icon_data_{};

  // 当前托盘图标句柄。
  HICON icon_ = nullptr;

  // 托盘图标是否已加入通知区。
  bool tray_icon_added_ = false;

  // 悬浮窗菜单项当前是否勾选。
  bool floating_enabled_ = false;

  // Explorer 重启后恢复托盘图标的消息标识。
  UINT taskbar_created_message_ = 0;
};

#endif  // RUNNER_WINDOWS_TRAY_CONTROLLER_H_
