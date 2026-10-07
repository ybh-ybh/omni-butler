#ifndef RUNNER_WINDOWS_TITLE_BAR_CONTROLLER_H_
#define RUNNER_WINDOWS_TITLE_BAR_CONTROLLER_H_

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// 为真实主窗口保存主题，并在系统修改窗口装饰后恢复应用配色。
class WindowsTitleBarController {
 public:
  // 注册主窗口标题栏主题通道。
  explicit WindowsTitleBarController(flutter::BinaryMessenger* messenger);

  // 卸载窗口消息钩子，避免窗口持有已释放的控制器。
  ~WindowsTitleBarController();

  // 控制器与窗口钩子一一对应，禁止复制。
  WindowsTitleBarController(const WindowsTitleBarController&) = delete;

  // 禁止通过赋值复制窗口所有权。
  WindowsTitleBarController& operator=(const WindowsTitleBarController&) = delete;

 private:
  // 解码、验证并应用 Dart 提交的标题栏主题。
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // 将窗口按钮命令投递到正常消息循环，避免 Dart 同步 FFI 阻塞新尺寸帧。
  void HandleWindowCommand(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // 将主题恢复钩子绑定到唯一主窗口。
  bool AttachWindow(HWND window);

  // 移除当前窗口的消息钩子并清空句柄。
  void DetachWindow();

  // 按明暗、背景、文字顺序应用主题，精确颜色不可用时保留明暗回退。
  HRESULT ApplySavedTheme(bool* exact_colors_applied = nullptr);

  // 按需切换 Flutter 自绘标题栏，仅移除或恢复原生标题栏样式。
  bool SetCustomCaption(bool enabled);

  // 根据当前 DPI 返回自绘标题栏拖动、顶边缩放或普通客户区命中。
  LRESULT HitTestCustomFrame(LPARAM lparam) const;

  // 绑定覆盖客户区的 Flutter 子窗口，让拖动区命中穿透到主窗口。
  bool AttachContentWindow();

  // 解除 Flutter 子窗口的命中测试钩子。
  void DetachContentWindow();

  // 只让自绘标题栏的拖动区域穿透，不改变按钮或业务区域的输入。
  static LRESULT CALLBACK ContentSubclassProc(
      HWND window, UINT message, WPARAM wparam, LPARAM lparam,
      UINT_PTR subclass_id, DWORD_PTR reference);

  // 先交给引擎处理系统主题消息，再恢复应用选择的窗口装饰。
  static LRESULT CALLBACK WindowSubclassProc(
      HWND window, UINT message, WPARAM wparam, LPARAM lparam,
      UINT_PTR subclass_id, DWORD_PTR reference);

  // 标题栏主题方法通道。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;

  // 当前唯一主窗口句柄。
  HWND window_ = nullptr;

  // 当前主窗口内部覆盖客户区的 Flutter 视图句柄。
  HWND content_window_ = nullptr;

  // 根据实际标题栏底色选择的按钮明暗。
  BOOL dark_ = FALSE;

  // 不含透明度的 Windows 标题栏背景色。
  COLORREF background_ = RGB(255, 255, 255);

  // 不含透明度的 Windows 标题栏文字色。
  COLORREF foreground_ = RGB(0, 0, 0);

  // 防止 DWM 更新期间的嵌套主题消息再次进入更新。
  bool applying_theme_ = false;

  // 当前是否由 Flutter 绘制标题栏，原生层只保留窗口交互。
  bool custom_caption_ = false;

  // 隐藏前的标题栏样式位；恢复时保留当下可见、最大化和最小化状态。
  LONG_PTR original_style_ = 0;

  // Flutter 自绘标题栏的逻辑像素高度。
  int caption_height_ = 28;

  // Flutter 右侧窗口按钮占用的逻辑像素宽度。
  int caption_buttons_width_ = 138;
};

#endif  // RUNNER_WINDOWS_TITLE_BAR_CONTROLLER_H_
