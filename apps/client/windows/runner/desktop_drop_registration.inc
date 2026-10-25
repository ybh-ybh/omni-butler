// 保持 desktop_drop 的事件协议，在真实 Flutter 视图出现后再注册 OLE。
class DesktopDropPlugin : public flutter::Plugin {
 public:
  // 引擎启动时只安装通道，不依赖不存在的 implicit view。
  explicit DesktopDropPlugin(flutter::PluginRegistrarWindows* registrar)
      : registrar_(registrar),
        channel_(std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), "desktop_drop",
            &flutter::StandardMethodCodec::GetInstance())) {
    channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      if (call.method_name() != "initializeView") {
        result->NotImplemented();
        return;
      }
      // 接收 Dart 当前 FlutterView 的真实身份，而不是猜测窗口句柄。
      int64_t view_id = -1;
      if (call.arguments()) {
        if (const auto value32 = std::get_if<int32_t>(call.arguments())) view_id = *value32;
        if (const auto value64 = std::get_if<int64_t>(call.arguments())) view_id = *value64;
      }
      // 查找发生在创建窗口之后，且只允许本引擎实际存在的视图。
      const auto view = view_id < 0 ? nullptr : registrar_->GetViewById(view_id);
      if (!view || !::IsWindow(view->GetNativeWindow())) {
        result->Error("invalid_view", "文件拖放目标视图不存在");
        return;
      }
      // OLE 绑定使用渲染视图客户区，与 Dart 的全局指针坐标对齐。
      const HWND window = view->GetNativeWindow();
      if (window_ == window && target_ && view_id_ == view_id) {
        result->Success(flutter::EncodableValue(true));
        return;
      }
      Detach();
      target_ = new DesktopDropTarget(channel_, window);
      target_->AddRef();
      // 只有实际注册成功才向客户端宣布可接收文件。
      const HRESULT status = target_->registration_result();
      if (FAILED(status)) {
        target_->Release();
        target_ = nullptr;
        result->Error("drop_registration_failed", "无法注册窗口文件拖放");
        return;
      }
      window_ = window;
      view_id_ = view_id;
      result->Success(flutter::EncodableValue(true));
    });
  }

  // 插件销毁前撤销 COM 注册，不能留下调用已销毁消息通道的目标。
  ~DesktopDropPlugin() override {
    channel_->SetMethodCallHandler(nullptr);
    Detach();
  }

  // 注册到引擎时插件必须存活，即使此时尚未创建任何窗口。
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
    registrar->AddPlugin(std::make_unique<DesktopDropPlugin>(registrar));
  }

 private:
  // 先撤销 OLE 所有权，再释放插件持有的引用。
  void Detach() {
    if (target_) {
      target_->Detach();
      target_->Release();
      target_ = nullptr;
    }
    window_ = nullptr;
    view_id_ = -1;
  }

  // 引擎提供的注册器，其生命周期长于插件。
  flutter::PluginRegistrarWindows* registrar_;
  // 插件和投放目标共享通道，处理器仅捕获插件裸指针避免引用环。
  FlutterMethodChannel channel_;
  // 当前唯一主聊天视图的 OLE 目标。
  DesktopDropTarget* target_ = nullptr;
  // 目标所在的真实渲染窗口。
  HWND window_ = nullptr;
  // 窗口句柄被系统复用时仍按视图身份重新绑定。
  int64_t view_id_ = -1;
};

// 每次绑定配对初始化 OLE，注册失败也保持可审计的返回值。
DesktopDropTarget::DesktopDropTarget(FlutterMethodChannel channel, HWND window_handle)
    : channel_(std::move(channel)), window_handle_(window_handle), ref_count_(0),
      need_revoke_ole_initialize_(false) {
  // OLE 与目标窗口共用当前平台消息线程。
  const HRESULT initialized = ::OleInitialize(nullptr);
  if (SUCCEEDED(initialized)) {
    need_revoke_ole_initialize_ = true;
    registration_result_ = ::RegisterDragDrop(window_handle_, this);
  } else {
    registration_result_ = initialized;
  }
}
