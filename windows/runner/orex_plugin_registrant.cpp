#include "orex_plugin_registrant.h"

#include <audioplayers_windows/audioplayers_windows_plugin.h>
#include <connectivity_plus/connectivity_plus_windows_plugin.h>
#include <desktop_drop/desktop_drop_plugin.h>
#include <flutter_secure_storage_windows/flutter_secure_storage_windows_plugin.h>
#include <flutter_webrtc/flutter_web_r_t_c_plugin.h>
#include <livekit_client/live_kit_plugin.h>
#include <record_windows/record_windows_plugin_c_api.h>
#include <sqlcipher_flutter_libs/sqlite3_flutter_libs_plugin.h>

namespace {

FlutterDesktopPluginRegistrarRef Registrar(FlutterDesktopEngineRef engine,
                                           const char* name) {
  return FlutterDesktopEngineGetPluginRegistrar(engine, name);
}

}  // namespace

void RegisterOrexPlugins(FlutterDesktopEngineRef engine) {
  AudioplayersWindowsPluginRegisterWithRegistrar(
      Registrar(engine, "AudioplayersWindowsPlugin"));
  ConnectivityPlusWindowsPluginRegisterWithRegistrar(
      Registrar(engine, "ConnectivityPlusWindowsPlugin"));
  DesktopDropPluginRegisterWithRegistrar(
      Registrar(engine, "DesktopDropPlugin"));
  FlutterSecureStorageWindowsPluginRegisterWithRegistrar(
      Registrar(engine, "FlutterSecureStorageWindowsPlugin"));
  FlutterWebRTCPluginRegisterWithRegistrar(
      Registrar(engine, "FlutterWebRTCPlugin"));
  LiveKitPluginRegisterWithRegistrar(Registrar(engine, "LiveKitPlugin"));
  RecordWindowsPluginCApiRegisterWithRegistrar(
      Registrar(engine, "RecordWindowsPluginCApi"));
  Sqlite3FlutterLibsPluginRegisterWithRegistrar(
      Registrar(engine, "Sqlite3FlutterLibsPlugin"));
}
