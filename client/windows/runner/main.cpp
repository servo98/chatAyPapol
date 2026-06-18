#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shobjidl.h>
#include <windows.h>

#include "audio_session.h"
#include "flutter_window.h"
#include "utils.h"

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

  // AppUserModelID explícito y estable: ancla el ícono de la barra de tareas a
  // la app (sin esto Windows deriva un id por proceso y a veces sirve un ícono
  // cacheado/erróneo en arranques posteriores).
  ::SetCurrentProcessExplicitAppUserModelID(L"ChatPapol");

  // Renombra la sesión de audio de WebRTC ("RemoteAudioApp") por "ChatPapol"
  // en el Mezclador de volumen. Hilo de fondo (la sesión nace al entrar a voz).
  StartAudioSessionRenamer(L"ChatPapol");

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"chatpapol", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  StopAudioSessionRenamer();
  ::CoUninitialize();

  // Cierre DURO. Al salir del loop, el runtime de C++ intenta destruir los
  // estáticos de libwebrtc.dll (hilos del ADM de audio); ahí se cuelga y el
  // proceso queda vivo —con su sesión en el Mezclador de volumen— por más que
  // la ventana ya no esté. La voz se desconectó antes (Dart: onWindowClose →
  // voice.leave()), así que aquí ya es seguro matar el proceso de inmediato.
  ::TerminateProcess(::GetCurrentProcess(), EXIT_SUCCESS);
  return EXIT_SUCCESS;
}
