#include "desktop_drop_plugin.cpp"

#include <shlobj.h>
#include <cstring>

// 记录真实 StandardMethodCodec 发出的原生事件，不连接 Dart 或用户数据。
class RecordingMessenger : public flutter::BinaryMessenger {
 public:
  // 有序保存方法名及其参数。
  mutable std::vector<std::pair<std::string, flutter::EncodableValue>> messages;
  // 解码插件实际发送的消息，而不是手写预期事件。
  void Send(const std::string&, const uint8_t* bytes, size_t length,
            flutter::BinaryReply = nullptr) const override {
    // 系统回调生成的实际方法和附件路径。
    const auto call = flutter::StandardMethodCodec::GetInstance().DecodeMethodCall(bytes, length);
    messages.emplace_back(call->method_name(), call->arguments() ? *call->arguments() : flutter::EncodableValue());
  }
  // 仅测试目标发出的回调，不安装全局方法处理器。
  void SetMessageHandler(const std::string&, flutter::BinaryMessageHandler) override {}
};

// 合成资源管理器的 CF_HDROP 载荷，不读取或移动真实文件。
class FileDataObject : public IDataObject {
 public:
  // 原生回调需要传递的中文长路径。
  std::wstring path = L"C:\\" + std::wstring(1000, L'中') + L"\\附件.png";
  // 可切换为纯文本拖动，验证不出现文件添加事件。
  bool file_payload = true;
  // 测试对象由栈持有，引用计数只满足 COM 查询约定。
  ULONG references = 1;
  // 只公开 IDataObject 与 IUnknown。
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** output) override {
    *output = nullptr;
    if (iid != IID_IUnknown && iid != IID_IDataObject) return E_NOINTERFACE;
    *output = static_cast<IDataObject*>(this);
    AddRef();
    return S_OK;
  }
  // 系统保留一次对象引用。
  ULONG STDMETHODCALLTYPE AddRef() override { return ++references; }
  // 本测试栈对象不在 Release 时释放内存。
  ULONG STDMETHODCALLTYPE Release() override { return --references; }
  // 只允许实际文件格式及全局内存介质。
  HRESULT STDMETHODCALLTYPE QueryGetData(FORMATETC* format) override {
    return file_payload && format->cfFormat == CF_HDROP && (format->tymed & TYMED_HGLOBAL) ? S_OK : DV_E_FORMATETC;
  }
  // 构建可由系统 DragQueryFileW 读取的真实全局内存格式。
  HRESULT STDMETHODCALLTYPE GetData(FORMATETC* format, STGMEDIUM* medium) override {
    if (FAILED(QueryGetData(format))) return DV_E_FORMATETC;
    // 载荷包含一个文件名和双终止符。
    const SIZE_T bytes = sizeof(DROPFILES) + (path.size() + 2) * sizeof(wchar_t);
    // 介质由 ReleaseStgMedium 负责释放。
    const HGLOBAL memory = ::GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, bytes);
    if (!memory) return E_OUTOFMEMORY;
    // 写入 Unicode 文件清单。
    auto* payload = static_cast<DROPFILES*>(::GlobalLock(memory));
    payload->pFiles = sizeof(DROPFILES);
    payload->fWide = TRUE;
    std::memcpy(reinterpret_cast<char*>(payload) + sizeof(DROPFILES), path.c_str(), path.size() * sizeof(wchar_t));
    ::GlobalUnlock(memory);
    medium->tymed = TYMED_HGLOBAL;
    medium->hGlobal = memory;
    medium->pUnkForRelease = nullptr;
    return S_OK;
  }
  // 本测试不支持调用方提供缓冲区。
  HRESULT STDMETHODCALLTYPE GetDataHere(FORMATETC*, STGMEDIUM*) override { return E_NOTIMPL; }
  // 不提供额外的规范化格式。
  HRESULT STDMETHODCALLTYPE GetCanonicalFormatEtc(FORMATETC*, FORMATETC*) override { return E_NOTIMPL; }
  // 测试数据始终只读。
  HRESULT STDMETHODCALLTYPE SetData(FORMATETC*, STGMEDIUM*, BOOL) override { return E_NOTIMPL; }
  // 目标仅调用 QueryGetData，无需格式枚举。
  HRESULT STDMETHODCALLTYPE EnumFormatEtc(DWORD, IEnumFORMATETC**) override { return E_NOTIMPL; }
  // 不建立通知订阅。
  HRESULT STDMETHODCALLTYPE DAdvise(FORMATETC*, DWORD, IAdviseSink*, DWORD*) override { return OLE_E_ADVISENOTSUPPORTED; }
  // 不存在需要撤销的订阅。
  HRESULT STDMETHODCALLTYPE DUnadvise(DWORD) override { return OLE_E_ADVISENOTSUPPORTED; }
  // 不提供通知枚举。
  HRESULT STDMETHODCALLTYPE EnumDAdvise(IEnumSTATDATA**) override { return OLE_E_ADVISENOTSUPPORTED; }
};

// 在真实隐藏 HWND 上验证 OLE 注册、文件事件、复制语义和失败清理。
int main() {
  // 不显示窗口，不访问用户正在运行的实例。
  const HWND window = ::CreateWindowExW(0, L"STATIC", L"Omni drop native test", WS_POPUP, 0, 0, 640, 480, nullptr, nullptr, ::GetModuleHandle(nullptr), nullptr);
  if (!window) return 1;
  // 真实编解码器接收端。
  RecordingMessenger messenger;
  // 与生产插件相同的消息通道。
  const auto channel = std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(&messenger, "desktop_drop", &flutter::StandardMethodCodec::GetInstance());
  // 第一个窗口投放目标必须实际注册成功。
  auto* target = new DesktopDropTarget(channel, window);
  target->AddRef();
  if (FAILED(target->registration_result())) return 2;
  // 失败的重复注册不得撤销第一个合法目标。
  auto* duplicate = new DesktopDropTarget(channel, window);
  duplicate->AddRef();
  if (duplicate->registration_result() != DRAGDROP_E_ALREADYREGISTERED) return 3;
  duplicate->Release();
  // 失败目标销毁后，系统仍应报告第一个目标占有该窗口。
  auto* still_duplicate = new DesktopDropTarget(channel, window);
  still_duplicate->AddRef();
  if (still_duplicate->registration_result() != DRAGDROP_E_ALREADYREGISTERED) return 9;
  still_duplicate->Release();
  // 合成含中文长路径的系统文件数据对象。
  FileDataObject data;
  // 系统提供的屏幕物理坐标。
  POINTL location{10, 10};
  // 来源允许复制或移动，但目标只能选择复制。
  DWORD effect = DROPEFFECT_COPY | DROPEFFECT_MOVE;
  target->DragEnter(&data, 0, location, &effect);
  if (effect != DROPEFFECT_COPY) return 4;
  target->Drop(&data, 0, location, &effect);
  if (effect != DROPEFFECT_COPY || messenger.messages.size() != 3 || messenger.messages.back().first != "performOperation") return 5;
  // 系统 DragQueryFileW 解出的真实列表必须完整保留中文长路径。
  const auto& files = std::get<flutter::EncodableList>(messenger.messages.back().second);
  if (files.size() != 1 || std::get<std::string>(files.front()) != ws2s(data.path)) return 6;
  data.file_payload = false;
  target->DragEnter(&data, 0, location, &effect);
  if (effect != DROPEFFECT_NONE || messenger.messages.size() != 3) return 7;
  data.file_payload = true;
  effect = DROPEFFECT_MOVE;
  target->DragEnter(&data, 0, location, &effect);
  if (effect != DROPEFFECT_NONE || messenger.messages.size() != 3) return 10;
  data.path.clear();
  effect = DROPEFFECT_COPY;
  target->DragEnter(&data, 0, location, &effect);
  target->Drop(&data, 0, location, &effect);
  if (effect != DROPEFFECT_NONE || messenger.messages.back().first != "exited") return 11;
  target->Detach();
  target->Release();
  // 原目标清理完成后，同一窗口必须可以重新注册。
  auto* rebound = new DesktopDropTarget(channel, window);
  rebound->AddRef();
  if (FAILED(rebound->registration_result())) return 8;
  rebound->Detach();
  rebound->Release();
  ::DestroyWindow(window);
  std::cout << "NATIVE_DROP_PASSED: actual OLE registration, Unicode CF_HDROP, copy only, cleanup" << std::endl;
  return 0;
}
