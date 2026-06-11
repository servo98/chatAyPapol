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

// Ruta del .exe + índice 0 = el ícono embebido (Runner.rc → app_icon.ico). Es
// lo que el Mezclador de volumen pinta junto al nombre de la sesión.
const std::wstring& SelfIconPath() {
  static const std::wstring path = [] {
    wchar_t buf[MAX_PATH] = {0};
    DWORD n = GetModuleFileNameW(nullptr, buf, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return std::wstring();
    return std::wstring(buf) + L",0";
  }();
  return path;
}

// Recorre TODOS los endpoints de render activos y, para CADA sesión de audio de
// ESTE proceso, fija el display name y el ícono a los de ChatPapol. Antes solo
// tocaba las que se llamaban exacto "RemoteAudioApp" (frágil: si libwebrtc
// cambia ese string, no renombraba nada y quedaba el ícono rojo genérico). Como
// toda sesión de nuestro PID es nuestra, las marcamos todas. Idempotente: solo
// escribe si difiere. No toca sesiones de otros procesos. Devuelve cuántas tocó.
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
                bool touched = false;
                LPWSTR name = nullptr;
                if (SUCCEEDED(ctrl2->GetDisplayName(&name))) {
                  if (!name || wcscmp(name, desired) != 0) {
                    ctrl2->SetDisplayName(desired, nullptr);
                    touched = true;
                  }
                  if (name) CoTaskMemFree(name);
                }
                const std::wstring& icon = SelfIconPath();
                if (!icon.empty()) {
                  LPWSTR cur = nullptr;
                  if (SUCCEEDED(ctrl2->GetIconPath(&cur))) {
                    if (!cur || wcscmp(cur, icon.c_str()) != 0) {
                      ctrl2->SetIconPath(icon.c_str(), nullptr);
                      touched = true;
                    }
                    if (cur) CoTaskMemFree(cur);
                  }
                }
                if (touched) ++renamed;
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
