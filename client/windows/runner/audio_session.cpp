#include "audio_session.h"

#include <windows.h>
#include <audiopolicy.h>
#include <mmdeviceapi.h>
#include <objbase.h>

#include <atomic>
#include <string>
#include <thread>

namespace {

std::atomic<bool> g_running{false};
std::wstring g_desired_name;

// El default horneado en libwebrtc.dll que muestra el Mezclador de volumen.
constexpr const wchar_t kWebrtcSessionName[] = L"RemoteAudioApp";

// Recorre TODOS los endpoints de render activos y renombra las sesiones de
// audio de ESTE proceso cuyo display name sea "RemoteAudioApp". Devuelve
// cuántas renombró (0 si aún no existe la sesión, p.ej. fuera de un canal de
// voz). No toca sesiones de otros procesos.
int RenameOnce(const wchar_t* desired) {
  int renamed = 0;
  IMMDeviceEnumerator* enumerator = nullptr;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                              __uuidof(IMMDeviceEnumerator),
                              reinterpret_cast<void**>(&enumerator)))) {
    return 0;
  }

  IMMDeviceCollection* devices = nullptr;
  if (SUCCEEDED(enumerator->EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE,
                                               &devices))) {
    UINT count = 0;
    devices->GetCount(&count);
    const DWORD self_pid = GetCurrentProcessId();
    for (UINT i = 0; i < count; ++i) {
      IMMDevice* device = nullptr;
      if (FAILED(devices->Item(i, &device)) || !device) continue;

      IAudioSessionManager2* mgr = nullptr;
      if (SUCCEEDED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL,
                                     nullptr,
                                     reinterpret_cast<void**>(&mgr)))) {
        IAudioSessionEnumerator* sessions = nullptr;
        if (SUCCEEDED(mgr->GetSessionEnumerator(&sessions))) {
          int scount = 0;
          sessions->GetCount(&scount);
          for (int s = 0; s < scount; ++s) {
            IAudioSessionControl* ctrl = nullptr;
            if (FAILED(sessions->GetSession(s, &ctrl)) || !ctrl) continue;
            IAudioSessionControl2* ctrl2 = nullptr;
            if (SUCCEEDED(ctrl->QueryInterface(
                    __uuidof(IAudioSessionControl2),
                    reinterpret_cast<void**>(&ctrl2)))) {
              DWORD pid = 0;
              ctrl2->GetProcessId(&pid);
              if (pid == self_pid) {
                LPWSTR name = nullptr;
                if (SUCCEEDED(ctrl2->GetDisplayName(&name)) && name) {
                  if (wcscmp(name, kWebrtcSessionName) == 0) {
                    ctrl2->SetDisplayName(desired, nullptr);
                    ++renamed;
                  }
                  CoTaskMemFree(name);
                }
              }
              ctrl2->Release();
            }
            ctrl->Release();
          }
          sessions->Release();
        }
        mgr->Release();
      }
      device->Release();
    }
    devices->Release();
  }
  enumerator->Release();
  return renamed;
}

void RenamerThread() {
  // El hilo necesita su propio apartment COM (independiente del de wWinMain).
  if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) return;
  while (g_running.load()) {
    RenameOnce(g_desired_name.c_str());
    ::Sleep(1500);
  }
  CoUninitialize();
}

}  // namespace

void StartAudioSessionRenamer(const wchar_t* desired_name) {
  if (g_running.exchange(true)) return;  // ya corriendo
  g_desired_name = desired_name;
  std::thread(RenamerThread).detach();
}

void StopAudioSessionRenamer() { g_running.store(false); }
