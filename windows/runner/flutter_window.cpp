#include "flutter_window.h"

#include <windows.h>
#include <shellapi.h>
#include <mmdeviceapi.h>
#include <propvarutil.h>
#include <propsys.h>
#include <wrl/client.h>

#include <optional>
#include <string>
#include <variant>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

namespace {

using Microsoft::WRL::ComPtr;

constexpr PROPERTYKEY kPkeyDeviceFriendlyName = {
    {0xa45c254e, 0xdf1c, 0x4efd, {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}},
    14,
};

constexpr UINT kNotificationCallbackMessage = WM_APP + 42;
constexpr UINT kNotificationIconId = 1;

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) return std::wstring();
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, nullptr, 0);
  if (size <= 1) return std::wstring();
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(), -1, result.data(), size);
  result.pop_back();
  return result;
}

std::string MapString(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return std::string();
  const auto* value = std::get_if<std::string>(&it->second);
  return value == nullptr ? std::string() : *value;
}

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return std::string();
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr,
                                       0, nullptr, nullptr);
  if (size <= 1) return std::string();
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, result.data(), size,
                      nullptr, nullptr);
  result.pop_back();
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

  audio_devices_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
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

  push_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "orex/push",
      &flutter::StandardMethodCodec::GetInstance());
  push_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto* arguments =
            call.arguments() == nullptr
                ? nullptr
                : std::get_if<flutter::EncodableMap>(call.arguments());
        if (call.method_name() == "showLocalMatrixNotification") {
          if (arguments == nullptr) {
            result->Success(flutter::EncodableValue(false));
            return;
          }
          ShowWindowsNotification(*arguments);
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (call.method_name() == "dismissRoomNotifications") {
          if (arguments != nullptr) {
            DismissWindowsNotification(MapString(*arguments, "roomId"));
          }
          result->Success(flutter::EncodableValue(true));
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
  DismissWindowsNotification(notification_room_id_);
  push_channel_ = nullptr;
  audio_devices_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::ShowWindowsNotification(
    const flutter::EncodableMap& payload) {
  const std::string title = MapString(payload, "title");
  const std::string body = MapString(payload, "body");
  const std::string room_id = MapString(payload, "room_id");
  if (title.empty() || body.empty() || room_id.empty() ||
      GetHandle() == nullptr) {
    return;
  }
  if (!notification_icon_added_) {
    notification_icon_ = {};
    notification_icon_.cbSize = sizeof(NOTIFYICONDATAW);
    notification_icon_.hWnd = GetHandle();
    notification_icon_.uID = kNotificationIconId;
    notification_icon_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    notification_icon_.uCallbackMessage = kNotificationCallbackMessage;
    notification_icon_.hIcon = static_cast<HICON>(LoadImageW(
        GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
        LR_DEFAULTCOLOR));
    wcscpy_s(notification_icon_.szTip, L"Orex Messenger");
    notification_icon_added_ =
        Shell_NotifyIconW(NIM_ADD, &notification_icon_) == TRUE;
  }
  if (!notification_icon_added_) return;

  const std::wstring wide_title = Utf8ToWide(title);
  const std::wstring wide_body = Utf8ToWide(body);
  wcsncpy_s(notification_icon_.szInfoTitle, wide_title.c_str(), _TRUNCATE);
  wcsncpy_s(notification_icon_.szInfo, wide_body.c_str(), _TRUNCATE);
  notification_icon_.dwInfoFlags = NIIF_INFO | NIIF_RESPECT_QUIET_TIME;
  notification_icon_.uFlags = NIF_INFO;
  Shell_NotifyIconW(NIM_MODIFY, &notification_icon_);

  notification_payload_ = payload;
  notification_room_id_ = room_id;
}

void FlutterWindow::DismissWindowsNotification(const std::string& room_id) {
  if (!room_id.empty() && room_id != notification_room_id_) return;
  if (notification_icon_added_) {
    Shell_NotifyIconW(NIM_DELETE, &notification_icon_);
    notification_icon_added_ = false;
  }
  notification_payload_.clear();
  notification_room_id_.clear();
}

void FlutterWindow::ActivateNotification() {
  if (GetHandle() != nullptr) {
    ShowWindow(GetHandle(), SW_RESTORE);
    SetForegroundWindow(GetHandle());
  }
  if (push_channel_ && !notification_payload_.empty()) {
    push_channel_->InvokeMethod(
        "onNotificationOpened",
        std::make_unique<flutter::EncodableValue>(notification_payload_));
  }
  DismissWindowsNotification(notification_room_id_);
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
    case kNotificationCallbackMessage:
      if (lparam == NIN_BALLOONUSERCLICK || lparam == WM_LBUTTONUP) {
        ActivateNotification();
      } else if (lparam == NIN_BALLOONHIDE || lparam == NIN_BALLOONTIMEOUT) {
        DismissWindowsNotification(notification_room_id_);
      }
      return 0;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
