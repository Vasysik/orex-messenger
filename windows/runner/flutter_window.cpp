#include "flutter_window.h"

#include <windows.h>
#include <mmdeviceapi.h>
#include <propvarutil.h>
#include <propsys.h>
#include <wrl/client.h>

#include <optional>
#include <string>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

using Microsoft::WRL::ComPtr;

constexpr PROPERTYKEY kPkeyDeviceFriendlyName = {
    {0xa45c254e, 0xdf1c, 0x4efd, {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}},
    14,
};

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return std::string();
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr,
                                       0, nullptr, nullptr);
  if (size <= 1) return std::string();
  std::string result(size - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, result.data(), size,
                      nullptr, nullptr);
  return result;
}

std::string DeviceFriendlyName(IMMDevice* device) {
  ComPtr<IPropertyStore> store;
  if (FAILED(device->OpenPropertyStore(STGM_READ, &store)) || !store) {
    return "Аудиоустройство";
  }

  PROPVARIANT value;
  PropVariantInit(&value);
  std::string name = "Аудиоустройство";
  if (SUCCEEDED(store->GetValue(kPkeyDeviceFriendlyName, &value)) &&
      value.vt == VT_LPWSTR && value.pwszVal != nullptr) {
    name = WideToUtf8(value.pwszVal);
  }
  PropVariantClear(&value);
  return name.empty() ? "Аудиоустройство" : name;
}

flutter::EncodableList ListWindowsAudioDevices() {
  flutter::EncodableList devices;
  ComPtr<IMMDeviceEnumerator> enumerator;
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                              CLSCTX_ALL, IID_PPV_ARGS(&enumerator))) ||
      !enumerator) {
    return devices;
  }

  const struct EndpointConfig {
    EDataFlow flow;
    const char* kind;
  } endpoints[] = {
      {eRender, "audiooutput"},
      {eCapture, "audioinput"},
  };

  for (const auto& endpoint : endpoints) {
    ComPtr<IMMDeviceCollection> collection;
    if (FAILED(enumerator->EnumAudioEndpoints(endpoint.flow, DEVICE_STATE_ACTIVE,
                                              &collection)) ||
        !collection) {
      continue;
    }

    UINT count = 0;
    if (FAILED(collection->GetCount(&count))) continue;
    for (UINT i = 0; i < count; ++i) {
      ComPtr<IMMDevice> device;
      if (FAILED(collection->Item(i, &device)) || !device) continue;

      LPWSTR raw_id = nullptr;
      if (FAILED(device->GetId(&raw_id)) || raw_id == nullptr) continue;
      const std::string id = WideToUtf8(raw_id);
      CoTaskMemFree(raw_id);
      if (id.empty()) continue;

      flutter::EncodableMap item;
      item[flutter::EncodableValue("id")] = flutter::EncodableValue(id);
      item[flutter::EncodableValue("kind")] =
          flutter::EncodableValue(endpoint.kind);
      item[flutter::EncodableValue("label")] =
          flutter::EncodableValue(DeviceFriendlyName(device.Get()));
      devices.emplace_back(item);
    }
  }

  return devices;
}

}  // namespace

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

  audio_devices_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "orex/audio_devices",
      &flutter::StandardMethodCodec::GetInstance());
  audio_devices_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "listAudioDevices") {
          result->Success(flutter::EncodableValue(ListWindowsAudioDevices()));
          return;
        }
        if (call.method_name() == "selectAudioOutput") {
          // Windows output switching is applied by LiveKit/flutter_webrtc with
          // the WASAPI endpoint id returned by listAudioDevices().
          result->Success(flutter::EncodableValue());
          return;
        }
        result->NotImplemented();
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  audio_devices_channel_ = nullptr;
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
