#ifndef RUNNER_WINDOWS_FLOATING_CONTROLLER_H_
#define RUNNER_WINDOWS_FLOATING_CONTROLLER_H_

#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>

// 在原生消息线程同步父子视图尺寸，避免旧像素回拷和 Dart 同步等待。
class WindowsFloatingController {
 public:
  // 注册独立的悬浮窗尺寸通道。
  explicit WindowsFloatingController(flutter::BinaryMessenger* messenger);

 private:
  // 处理物理屏幕矩形更新，仅允许当前进程的有效窗口。
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // 原生尺寸更新方法通道。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_WINDOWS_FLOATING_CONTROLLER_H_
