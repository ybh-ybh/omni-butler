# 当前 SDK 3.47.2 无法使用要求 3.47.7 的 desktop_drop 0.9.x。
# 0.8.4 原生实现将 MAX_PATH 栈缓冲区配上字节数 cch，长路径可能越界。
# 仅在构建目录生成修正副本，不修改 pub 缓存或第三方原始文件。
function(omni_patch_desktop_drop)
  # 注册段变化也必须重新生成编译副本，不能被增量构建缓存忽略。
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/runner/desktop_drop_registration.inc")
  # Flutter 已根据锁文件注册的上游插件源码目录。
  get_target_property(omni_drop_source_dir desktop_drop_plugin SOURCE_DIR)
  # 固定版本源文件身份，依赖变化时必须重新审查补丁，不静默套用。
  set(omni_drop_original "${omni_drop_source_dir}/desktop_drop_plugin.cpp")
  file(SHA256 "${omni_drop_original}" omni_drop_hash)
  if(NOT omni_drop_hash STREQUAL "3c30e832a5a17ca182d085ea5322ffab6290dc0c56a0d166c0c5c6b225691f89")
    message(FATAL_ERROR "desktop_drop source changed; review Windows path compatibility patch")
  endif()
  # 保留上游许可证，局部修正窗口绑定、路径读取与文件事件语义。
  file(READ "${omni_drop_original}" omni_drop_source)
  string(PREPEND omni_drop_source "#include \"windows_dropped_file_path.h\"\n")
  # 通道由插件和真实 OLE 目标共同持有，等 Dart 提交 viewId 后绑定。
  string(REPLACE "using FlutterMethodChannel = std::unique_ptr<" "using FlutterMethodChannel = std::shared_ptr<"
    omni_drop_source "${omni_drop_source}")
  # 原生目标显式记录注册事实，失败目标不能撤销其他目标的窗口注册。
  string(REPLACE "virtual ~DesktopDropTarget();"
    "virtual ~DesktopDropTarget();\n        // 只返回实际 OLE 注册事实。\n        HRESULT registration_result() const { return registration_result_; }\n        // 先释放系统引用，避免 COM 引用环及销毁后回调。\n        void Detach() { if (SUCCEEDED(registration_result_)) { RevokeDragDrop(window_handle_); registration_result_ = E_FAIL; } }"
    omni_drop_source "${omni_drop_source}")
  string(REPLACE "bool need_revoke_ole_initialize_;"
    "bool need_revoke_ole_initialize_;\n        // 当前目标是否拥有窗口的 OLE 注册。\n        HRESULT registration_result_ = E_FAIL;\n        // 只允许文件载荷，且始终声明复制而不是移动原文件。\n        bool accepts_files_ = false;"
    omni_drop_source "${omni_drop_source}")
  # 使用可审查的本地注册段替换只查 implicit view 的旧实现。
  file(READ "${CMAKE_CURRENT_SOURCE_DIR}/runner/desktop_drop_registration.inc" omni_drop_registration)
  string(FIND "${omni_drop_source}" "    class DesktopDropPlugin : public flutter::Plugin {" omni_drop_start)
  string(FIND "${omni_drop_source}" "    HRESULT DesktopDropTarget::DragEnter" omni_drop_end)
  if(omni_drop_start LESS 0 OR omni_drop_end LESS omni_drop_start)
    message(FATAL_ERROR "desktop_drop registration section missing")
  endif()
  string(SUBSTRING "${omni_drop_source}" 0 ${omni_drop_start} omni_drop_prefix)
  string(SUBSTRING "${omni_drop_source}" ${omni_drop_end} -1 omni_drop_suffix)
  set(omni_drop_source "${omni_drop_prefix}${omni_drop_registration}\n${omni_drop_suffix}")
  string(REPLACE "RevokeDragDrop(window_handle_);\n        if (need_revoke_ole_initialize_)"
    "Detach();\n        if (need_revoke_ole_initialize_)" omni_drop_source "${omni_drop_source}")
  # 系统文件拖动明确标记复制，文本拖动不显示添加附件遮罩。
  string(REPLACE "HRESULT DesktopDropTarget::DragEnter(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {"
    "HRESULT DesktopDropTarget::DragEnter(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {\n        // 仅接受允许复制的系统文件载荷。\n        FORMATETC format = {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};\n        accepts_files_ = pDataObj && pDataObj->QueryGetData(&format) == S_OK && (*pdwEffect & DROPEFFECT_COPY);\n        *pdwEffect = accepts_files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;\n        if (!accepts_files_) return S_OK;"
    omni_drop_source "${omni_drop_source}")
  string(REPLACE "HRESULT DesktopDropTarget::DragOver(DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {"
    "HRESULT DesktopDropTarget::DragOver(DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {\n        *pdwEffect = accepts_files_ ? DROPEFFECT_COPY : DROPEFFECT_NONE;\n        if (!accepts_files_) return S_OK;"
    omni_drop_source "${omni_drop_source}")
  string(REPLACE "HRESULT DesktopDropTarget::DragLeave() {"
    "HRESULT DesktopDropTarget::DragLeave() {\n        accepts_files_ = false;" omni_drop_source "${omni_drop_source}")
  string(REPLACE "HRESULT DesktopDropTarget::Drop(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {"
    "HRESULT DesktopDropTarget::Drop(IDataObject *pDataObj, DWORD grfKeyState, POINTL pt, DWORD *pdwEffect) {\n        DragOver(grfKeyState, pt, pdwEffect);\n        if (!accepts_files_) return S_OK;\n        accepts_files_ = false;" omni_drop_source "${omni_drop_source}")
  string(REPLACE "TCHAR filename[MAX_PATH];"
    "const std::wstring wide = omni::ReadDroppedFilePath(reinterpret_cast<HDROP>(data), i);\n                        if (wide.empty()) continue;"
    omni_drop_source "${omni_drop_source}")
  string(REPLACE "DragQueryFile(reinterpret_cast<HDROP>(data), i, filename, sizeof(TCHAR) * MAX_PATH);"
    "" omni_drop_source "${omni_drop_source}")
  string(REPLACE "std::wstring wide(filename);" "" omni_drop_source "${omni_drop_source}")
  string(REPLACE "std::cout << \"done: \" << path << std::endl;" "" omni_drop_source "${omni_drop_source}")
  # DragQueryFile 接收 HGLOBAL 句柄，不能把锁定后的数据地址当作句柄。
  string(REPLACE "reinterpret_cast<HDROP>(data)" "reinterpret_cast<HDROP>(stgmed.hGlobal)"
    omni_drop_source "${omni_drop_source}")
  string(REPLACE "channel_->InvokeMethod(\"performOperation\","
    "if (list.empty()) { *pdwEffect = DROPEFFECT_NONE; channel_->InvokeMethod(\"exited\", std::make_unique<flutter::EncodableValue>()); return S_OK; }\n        channel_->InvokeMethod(\"performOperation\","
    omni_drop_source "${omni_drop_source}")
  # 构建副本继续引用上游头文件，应用只提供有界的路径读取函数。
  set(omni_drop_patched "${CMAKE_CURRENT_BINARY_DIR}/desktop_drop_compat/desktop_drop_plugin.cpp")
  file(WRITE "${omni_drop_patched}" "${omni_drop_source}")
  set_property(TARGET desktop_drop_plugin PROPERTY SOURCES "${omni_drop_patched}")
  target_include_directories(desktop_drop_plugin PRIVATE
    "${omni_drop_source_dir}" "${CMAKE_CURRENT_SOURCE_DIR}/runner")
endfunction()

omni_patch_desktop_drop()

# 原生链路回归使用同一份编译副本，测试目标独立于发布包。
add_executable(windows_drop_native_test EXCLUDE_FROM_ALL
  "${CMAKE_CURRENT_SOURCE_DIR}/../test/support/windows_drop_native_test.cpp")
apply_standard_settings(windows_drop_native_test)
target_compile_definitions(windows_drop_native_test PRIVATE FLUTTER_PLUGIN_IMPL)
# 同时提供上游声明与应用局部兼容头，不复制第三方源代码进仓库。
get_target_property(omni_drop_test_source_dir desktop_drop_plugin SOURCE_DIR)
target_include_directories(windows_drop_native_test PRIVATE
  "${CMAKE_CURRENT_BINARY_DIR}/desktop_drop_compat"
  "${omni_drop_test_source_dir}"
  "${CMAKE_CURRENT_SOURCE_DIR}/runner")
target_link_libraries(windows_drop_native_test PRIVATE flutter flutter_wrapper_plugin shell32 ole32 user32)
set_target_properties(windows_drop_native_test PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/tests")
