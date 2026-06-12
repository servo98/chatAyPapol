#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Canal 'chatpapol/window': Dart pide parpadear el botón de la barra de tareas
  // cuando llega un mensaje notificable y la ventana no está al frente. El propio
  // nativo verifica el foreground (a prueba de un windowFocused desincronizado en
  // Dart) y solo parpadea si NO estamos al frente. FLASHW_TIMERNOFG deja de
  // parpadear solo cuando el usuario trae la ventana al frente.
  window_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "chatpapol/window",
      &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "flashTaskbar") {
          HWND hwnd = GetHandle();
          if (hwnd && GetForegroundWindow() != hwnd) {
            FLASHWINFO fi = {sizeof(FLASHWINFO), hwnd,
                             FLASHW_TRAY | FLASHW_TIMERNOFG, 0, 0};
            FlashWindowEx(&fi);
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  // El runner muestra SIEMPRE la ventana en el primer frame (garantiza que
  // sea visible). window_manager solo le quita la barra del SO después, ya
  // mostrada. (No pasar titleBarStyle en WindowOptions: eso provocaba que la
  // ventana quedara invisible al arrancar.)
  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
