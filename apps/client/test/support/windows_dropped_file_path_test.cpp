#include "../../windows/runner/windows_dropped_file_path.h"

#include <algorithm>
#include <iostream>

namespace {

// 合成文件路径，不读取真实系统文件或拖放内容。
std::wstring source_path;
// 最后一次系统读取收到的字符容量。
UINT observed_capacity = 0;
// 模拟数据对象在两次查询之间发生变化。
bool changed_path = false;
// 模拟异常长度响应。
UINT forced_length = 0;

// 仿照 DragQueryFileW 检查调用方实际提供的缓冲区边界。
UINT WINAPI QueryPath(HDROP, UINT, LPWSTR buffer, UINT capacity) {
  if (buffer == nullptr) {
    return forced_length == 0 ? static_cast<UINT>(source_path.size()) : forced_length;
  }
  observed_capacity = capacity;
  if (capacity != source_path.size() + 1) return 0;
  std::copy(source_path.begin(), source_path.end(), buffer);
  buffer[source_path.size()] = L'\0';
  return static_cast<UINT>(source_path.size()) - (changed_path ? 1 : 0);
}

}  // namespace

// Release 模式也执行断言，覆盖中文长路径、空路径和变化/异常响应。
int main() {
  source_path = L"C:\\" + std::wstring(1000, L'中') + L"\\附件.png";
  if (omni::ReadDroppedFilePath(nullptr, 0, QueryPath) != source_path ||
      observed_capacity != source_path.size() + 1) return 1;
  changed_path = true;
  if (!omni::ReadDroppedFilePath(nullptr, 0, QueryPath).empty()) return 2;
  changed_path = false;
  source_path.clear();
  if (!omni::ReadDroppedFilePath(nullptr, 0, QueryPath).empty()) return 3;
  forced_length = 40000;
  observed_capacity = 0;
  if (!omni::ReadDroppedFilePath(nullptr, 0, QueryPath).empty() ||
      observed_capacity != 0) return 4;
  std::cout << "Windows dropped file path checks passed" << std::endl;
  return 0;
}
