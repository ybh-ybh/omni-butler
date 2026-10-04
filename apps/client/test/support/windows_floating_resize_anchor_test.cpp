#include <windows.h>

#include <cstdio>

namespace {
// 记录宿主已经变更、内部视图尚未更新时的右边界。
struct Probe {
  // 当前模拟渲染子窗口。
  HWND content = nullptr;
  // 本轮是否观察到中间状态。
  bool observed = false;
  // 中间状态的父子右边界差值。
  LONG right_error = 0;
};

// 在真实 WM_SIZE 消息入口测量，不仅检查 SetWindowPos 返回后的最终矩形。
LRESULT CALLBACK HostProc(HWND window, UINT message, WPARAM wparam,
                          LPARAM lparam) {
  if (message == WM_NCCREATE) {
    // 本测试窗口独立持有的测量上下文。
    const auto creation = reinterpret_cast<CREATESTRUCTW*>(lparam);
    ::SetWindowLongPtrW(window, GWLP_USERDATA,
                       reinterpret_cast<LONG_PTR>(creation->lpCreateParams));
  }
  // 当前宿主的测量上下文。
  const auto probe = reinterpret_cast<Probe*>(
      ::GetWindowLongPtrW(window, GWLP_USERDATA));
  if (message == WM_SIZE && probe && probe->content) {
    // 外层已更新后的屏幕矩形。
    RECT host{};
    // 子视图仍持有旧宽度时的屏幕矩形。
    RECT child{};
    ::GetWindowRect(window, &host);
    ::GetWindowRect(probe->content, &child);
    probe->observed = true;
    probe->right_error = child.right - host.right;
    // 与生产宿主相同，在读到中间状态之后更新内部视图。
    RECT client{};
    ::GetClientRect(window, &client);
    ::SetWindowPos(probe->content, nullptr, 0, 0, client.right, client.bottom,
                   SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOCOPYBITS);
    return 0;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

// 对比左锚定与右锚定宿主在左边缘缩放中的可见内容坐标。
bool CheckAnchor(DWORD extended_style, bool expect_stable,
                 bool desktop_child = false) {
  // 当前周期独立的测量上下文。
  Probe probe;
  // 隐藏的无边框测试宿主，不与用户的生产窗口交互。
  const HWND host = ::CreateWindowExW(
      0, L"OmniResizeAnchorTest", L"", WS_POPUP, 600, 100, 400, 500,
      nullptr, nullptr, ::GetModuleHandleW(nullptr), &probe);
  if (!host) return false;
  probe.content = ::CreateWindowExW(0, L"STATIC", L"", WS_CHILD, 0, 0, 400,
                                    500, host, nullptr,
                                    ::GetModuleHandleW(nullptr), nullptr);
  // 与生产一致：视图创建完成后再改变宿主样式，而非让视图继承镜像。
  ::SetWindowLongPtrW(host, GWL_EXSTYLE, extended_style);
  // 模拟 WorkerW 的独立隐藏父窗口，不修改真实桌面的窗口层级。
  const HWND desktop = desktop_child
                           ? ::CreateWindowExW(0, L"STATIC", L"", WS_POPUP,
                                               10, 10, 1600, 1000, nullptr,
                                               nullptr,
                                               ::GetModuleHandleW(nullptr),
                                               nullptr)
                           : nullptr;
  if (desktop_child && !desktop) {
    ::DestroyWindow(host);
    return false;
  }
  if (desktop) {
    ::SetWindowLongPtrW(host, GWL_STYLE, WS_CHILD);
    ::SetParent(host, desktop);
  }
  ::SetWindowPos(host, nullptr, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_FRAMECHANGED |
                     SWP_NOACTIVATE | SWP_NOZORDER);
  // 模拟左右往返的目标宽度，包括竖向和斜向更新。
  const int widths[] = {500, 420, 600, 400, 400, 550, 400};
  // 本周期全部中间状态是否符合预期。
  bool passed = probe.content != nullptr;
  // 原生子视图不能继承宿主的镜像坐标系。
  if (::GetWindowLongPtrW(probe.content, GWL_EXSTYLE) & WS_EX_LAYOUTRTL) {
    passed = false;
  }
  // 本轮需要验证的往返缩放序号。
  for (int index = 0; index < 7 && passed; ++index) {
    probe.observed = false;
    ::SetWindowPos(host, nullptr, 1000 - widths[index], 100, widths[index],
                   500 + index * 8,
                   SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOCOPYBITS);
    if (!probe.observed ||
        (expect_stable && probe.right_error != 0) ||
        (!expect_stable && index == 0 && probe.right_error == 0)) {
      passed = false;
    }
    std::printf("%s desktop=%d step=%d transient_right_error=%ld\n",
                expect_stable ? "right-anchor" : "left-anchor", desktop_child,
                index, probe.right_error);
    // 最终父子矩形仍需一致，不能以中间状态稳定换取错误的最终大小。
    RECT parent_bounds{};
    // 更新后的实际子视图屏幕矩形。
    RECT child_bounds{};
    ::GetWindowRect(host, &parent_bounds);
    ::GetWindowRect(probe.content, &child_bounds);
    passed = passed && ::EqualRect(&parent_bounds, &child_bounds);
  }
  ::DestroyWindow(host);
  if (desktop) ::DestroyWindow(desktop);
  return passed;
}
}  // namespace

// 独立 Win32 几何回归，不读取真实业务数据或用户偏好。
int main() {
  // 模拟 Flutter 的宿主窗口类，保留相同的重绘样式。
  WNDCLASSW window_class{};
  window_class.style = CS_HREDRAW | CS_VREDRAW;
  window_class.lpfnWndProc = HostProc;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.lpszClassName = L"OmniResizeAnchorTest";
  if (!::RegisterClassW(&window_class)) return 1;
  // 旧路径必须观测到旧宽度内容在右侧发生临时位移。
  const bool reproduced = CheckAnchor(0, false);
  // 新路径只改变宿主原点，子窗口始终保持正常的左到右坐标。
  const bool fixed = CheckAnchor(WS_EX_LAYOUTRTL | WS_EX_NOINHERITLAYOUT, true);
  // 同时覆盖生产卡片的桌面子窗口；不再启用导致画面抖动的整窗透明层。
  const bool desktop_fixed = CheckAnchor(
      WS_EX_LAYOUTRTL | WS_EX_NOINHERITLAYOUT | WS_EX_TOOLWINDOW,
      true, true);
  std::printf("%s: reproduced=%d right_anchor_stable=%d desktop_stable=%d\n",
              reproduced && fixed && desktop_fixed ? "PASS" : "FAIL",
              reproduced, fixed, desktop_fixed);
  return reproduced && fixed && desktop_fixed ? 0 : 1;
}
