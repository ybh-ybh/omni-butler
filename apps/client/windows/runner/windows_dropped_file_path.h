#pragma once

#include <windows.h>
#include <shellapi.h>

#include <string>
#include <vector>

namespace omni {

// 保留系统查询签名，原生回归可注入不访问真实剪贴板的查询。
using DroppedFileQuery = UINT(WINAPI*)(HDROP, UINT, LPWSTR, UINT);

// 以 UTF-16 字符数分配空间，拒绝空路径、超系统上限及两次查询间的变化。
inline std::wstring ReadDroppedFilePath(
    HDROP drop, UINT index, DroppedFileQuery query = &DragQueryFileW) {
  // Windows 扩展路径最多 32767 个字符，不接受异常数据对象触发巨量分配。
  const UINT length = query(drop, index, nullptr, 0);
  if (length == 0 || length > 32767) return {};
  // 多留一个终止符，cch 参数必须传字符数，不能传字节数。
  std::vector<wchar_t> buffer(length + 1, L'\0');
  if (query(drop, index, buffer.data(), length + 1) != length) return {};
  return std::wstring(buffer.data(), length);
}

}  // namespace omni
