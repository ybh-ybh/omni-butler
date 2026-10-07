#include <flutter/dart_project.h>
#include <flutter/flutter_engine.h>
#include <flutter/generated_plugin_registrant.h>

#include "utils.h"
#include "windows_tray_controller.h"
#include "windows_floating_controller.h"
#include "windows_title_bar_controller.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  // 传递给 Dart 入口的命令行参数。
  auto command_line_arguments{GetCommandLineArguments()};

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // 仅启动 Flutter 引擎，实际窗口由 Dart 多窗口 API 创建。
  auto const engine{std::make_shared<flutter::FlutterEngine>(project)};
  RegisterPlugins(engine.get());
  // 不依赖隐式 Flutter View 的系统托盘控制器。
  auto const tray_controller{
      std::make_unique<WindowsTrayController>(engine->messenger())};
  // 在原生消息线程更新悬浮窗尺寸，不从 Dart 手势栈同步等待新帧。
  auto const floating_controller{
      std::make_unique<WindowsFloatingController>(engine->messenger())};
  // 保存标题栏主题，并在系统重置原生窗口装饰后恢复应用配色。
  auto const title_bar_controller{
      std::make_unique<WindowsTitleBarController>(engine->messenger())};
  engine->Run();

  // Windows 消息循环。
  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
