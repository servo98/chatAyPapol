#ifndef RUNNER_AUDIO_SESSION_H_
#define RUNNER_AUDIO_SESSION_H_

// Renombra periódicamente la sesión de audio de WebRTC en el Mezclador de
// volumen de Windows. libwebrtc.dll deja horneado el display name
// "RemoteAudioApp"; este helper lo reescribe por [desired_name] para que en el
// mezclador se vea el nombre de la app. Arranca un hilo de fondo de bajo costo
// (sondea porque la sesión solo nace al entrar a voz y puede recrearse).
// Idempotente: llamarlo dos veces no hace nada.
void StartAudioSessionRenamer(const wchar_t* desired_name);

// Detiene el hilo (best-effort; al salir el proceso lo termina igual).
void StopAudioSessionRenamer();

#endif  // RUNNER_AUDIO_SESSION_H_
