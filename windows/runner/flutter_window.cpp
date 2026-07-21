#include "flutter_window.h"

#include <windows.h>
#include <shellapi.h>
#include <mmdeviceapi.h>
#include <propvarutil.h>
#include <propsys.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <cstring>
#include <optional>
#include <string>
#include <variant>
#include <vector>

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
constexpr UINT kTrayOpenCommand = 1001;
constexpr UINT kTrayExitCommand = 1002;
constexpr DWORD kMaxAvatarFileBytes = 8 * 1024 * 1024;
constexpr UINT kMaxAvatarDimension = 4096;

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

bool IsAvatarCacheFileName(const std::wstring& name) {
  if (name.size() != 16) return false;
  for (const wchar_t character : name) {
    if (!((character >= L'0' && character <= L'9') ||
          (character >= L'a' && character <= L'f'))) {
      return false;
    }
  }
  return true;
}

HICON LoadAvatarIcon(const std::string& raw_path) {
  const std::wstring path = Utf8ToWide(raw_path);
  const auto separator = path.find_last_of(L"\\/");
  if (path.empty() || separator == std::wstring::npos ||
      !IsAvatarCacheFileName(path.substr(separator + 1))) {
    return nullptr;
  }

  WIN32_FILE_ATTRIBUTE_DATA attributes{};
  if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard,
                            &attributes) ||
      (attributes.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
      attributes.nFileSizeHigh != 0 ||
      attributes.nFileSizeLow == 0 ||
      attributes.nFileSizeLow > kMaxAvatarFileBytes) {
    return nullptr;
  }

  ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory))) ||
      !factory) {
    return nullptr;
  }
  ComPtr<IWICBitmapDecoder> decoder;
  if (FAILED(factory->CreateDecoderFromFilename(
          path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnLoad,
          &decoder)) ||
      !decoder) {
    return nullptr;
  }
  ComPtr<IWICBitmapFrameDecode> frame;
  if (FAILED(decoder->GetFrame(0, &frame)) || !frame) return nullptr;

  UINT width = 0;
  UINT height = 0;
  if (FAILED(frame->GetSize(&width, &height)) || width == 0 || height == 0 ||
      width > kMaxAvatarDimension || height > kMaxAvatarDimension) {
    return nullptr;
  }

  const int system_icon_size = GetSystemMetrics(SM_CXICON);
  const UINT icon_size = system_icon_size > 0
                             ? static_cast<UINT>(system_icon_size)
                             : 32;
  IWICBitmapSource* source = frame.Get();
  ComPtr<IWICBitmapScaler> scaler;
  if (width != icon_size || height != icon_size) {
    if (FAILED(factory->CreateBitmapScaler(&scaler)) || !scaler ||
        FAILED(scaler->Initialize(frame.Get(), icon_size, icon_size,
                                  WICBitmapInterpolationModeFant))) {
      return nullptr;
    }
    source = scaler.Get();
  }

  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateFormatConverter(&converter)) || !converter ||
      FAILED(converter->Initialize(source, GUID_WICPixelFormat32bppPBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0.0,
                                   WICBitmapPaletteTypeCustom))) {
    return nullptr;
  }
  const UINT pixel_stride = icon_size * 4;
  std::vector<BYTE> pixels(static_cast<size_t>(pixel_stride) * icon_size);
  if (FAILED(converter->CopyPixels(nullptr, pixel_stride,
                                   static_cast<UINT>(pixels.size()),
                                   pixels.data()))) {
    return nullptr;
  }

  BITMAPV5HEADER bitmap_info{};
  bitmap_info.bV5Size = sizeof(bitmap_info);
  bitmap_info.bV5Width = static_cast<LONG>(icon_size);
  bitmap_info.bV5Height = -static_cast<LONG>(icon_size);
  bitmap_info.bV5Planes = 1;
  bitmap_info.bV5BitCount = 32;
  bitmap_info.bV5Compression = BI_BITFIELDS;
  bitmap_info.bV5RedMask = 0x00FF0000;
  bitmap_info.bV5GreenMask = 0x0000FF00;
  bitmap_info.bV5BlueMask = 0x000000FF;
  bitmap_info.bV5AlphaMask = 0xFF000000;
  bitmap_info.bV5CSType = LCS_sRGB;

  void* color_pixels = nullptr;
  HDC screen = GetDC(nullptr);
  HBITMAP color = CreateDIBSection(
      screen, reinterpret_cast<BITMAPINFO*>(&bitmap_info), DIB_RGB_COLORS,
      &color_pixels, nullptr, 0);
  if (screen != nullptr) ReleaseDC(nullptr, screen);
  if (color == nullptr || color_pixels == nullptr) {
    if (color != nullptr) DeleteObject(color);
    return nullptr;
  }
  std::memcpy(color_pixels, pixels.data(), pixels.size());

  const size_t mask_stride = ((static_cast<size_t>(icon_size) + 15) / 16) * 2;
  std::vector<BYTE> mask_pixels(mask_stride * icon_size, 0);
  HBITMAP mask = CreateBitmap(static_cast<int>(icon_size),
                              static_cast<int>(icon_size), 1, 1,
                              mask_pixels.data());
  if (mask == nullptr) {
    DeleteObject(color);
    return nullptr;
  }
  ICONINFO icon_info{};
  icon_info.fIcon = TRUE;
  icon_info.hbmColor = color;
  icon_info.hbmMask = mask;
  HICON icon = CreateIconIndirect(&icon_info);
  DeleteObject(mask);
  DeleteObject(color);
  return icon;
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
        if (call.method_name() == "activateIncomingCallWindow") {
          ActivateWindow();
          result->Success(flutter::EncodableValue(true));
          return;
        }
        result->NotImplemented();
      });

  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  // Keep one icon for the process lifetime. It is both the tray affordance and
  // the shell anchor for transient notification balloons.
  EnsureTrayIcon();

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
  if (destroyed_) return;
  destroyed_ = true;
  notification_payload_.clear();
  notification_room_id_.clear();
  RemoveTrayIcon();
  push_channel_ = nullptr;
  audio_devices_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

bool FlutterWindow::EnsureTrayIcon() {
  if (tray_icon_added_) return true;
  if (GetHandle() == nullptr) return false;

  ClearNotificationAvatarIcon();
  if (tray_icon_.hIcon != nullptr) {
    DestroyIcon(tray_icon_.hIcon);
    tray_icon_.hIcon = nullptr;
  }
  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(NOTIFYICONDATAW);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = kNotificationIconId;
  tray_icon_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_icon_.uCallbackMessage = kNotificationCallbackMessage;
  tray_icon_.hIcon = static_cast<HICON>(LoadImageW(
      GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
      LR_DEFAULTCOLOR));
#ifdef OREX_DEBUG_CHANNEL
  wcscpy_s(tray_icon_.szTip, L"Orex Messenger Debug");
#else
  wcscpy_s(tray_icon_.szTip, L"Orex Messenger");
#endif
  tray_icon_added_ = Shell_NotifyIconW(NIM_ADD, &tray_icon_) == TRUE;
  if (tray_icon_added_) {
    tray_icon_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &tray_icon_);
  }
  return tray_icon_added_;
}

void FlutterWindow::RemoveTrayIcon() {
  if (tray_icon_added_) {
    Shell_NotifyIconW(NIM_DELETE, &tray_icon_);
    tray_icon_added_ = false;
  }
  ClearNotificationAvatarIcon();
  if (tray_icon_.hIcon != nullptr) {
    DestroyIcon(tray_icon_.hIcon);
    tray_icon_.hIcon = nullptr;
  }
}

void FlutterWindow::ClearNotificationAvatarIcon() {
  tray_icon_.hBalloonIcon = nullptr;
  if (notification_avatar_icon_ != nullptr) {
    DestroyIcon(notification_avatar_icon_);
    notification_avatar_icon_ = nullptr;
  }
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
  if (!EnsureTrayIcon()) return;
  DismissWindowsNotification(notification_room_id_);

  const std::wstring wide_title = Utf8ToWide(title);
  const std::wstring wide_body = Utf8ToWide(body);
  ClearNotificationAvatarIcon();
  notification_avatar_icon_ =
      LoadAvatarIcon(MapString(payload, "sender_avatar_path"));
  tray_icon_.hBalloonIcon = notification_avatar_icon_;
  wcsncpy_s(tray_icon_.szInfoTitle, wide_title.c_str(), _TRUNCATE);
  wcsncpy_s(tray_icon_.szInfo, wide_body.c_str(), _TRUNCATE);
  tray_icon_.dwInfoFlags =
      (notification_avatar_icon_ != nullptr ? NIIF_USER | NIIF_LARGE_ICON
                                             : NIIF_INFO) |
      NIIF_RESPECT_QUIET_TIME;
  tray_icon_.uFlags = NIF_INFO;
  if (Shell_NotifyIconW(NIM_MODIFY, &tray_icon_) != TRUE) {
    ClearNotificationAvatarIcon();
    return;
  }

  notification_payload_ = payload;
  notification_room_id_ = room_id;
}

void FlutterWindow::DismissWindowsNotification(const std::string& room_id) {
  if (!room_id.empty() && room_id != notification_room_id_) return;
  notification_payload_.clear();
  notification_room_id_.clear();
  if (tray_icon_added_) {
    tray_icon_.szInfoTitle[0] = L'\0';
    tray_icon_.szInfo[0] = L'\0';
    tray_icon_.hBalloonIcon = nullptr;
    tray_icon_.dwInfoFlags = NIIF_NONE;
    tray_icon_.uFlags = NIF_INFO;
    Shell_NotifyIconW(NIM_MODIFY, &tray_icon_);
  }
  ClearNotificationAvatarIcon();
}

bool FlutterWindow::HideToTray() {
  HWND handle = GetHandle();
  if (handle == nullptr || !EnsureTrayIcon()) return false;
  hidden_to_tray_ = true;
  ShowWindow(handle, SW_HIDE);
  NotifyWindowVisibility(false);
  return true;
}

void FlutterWindow::NotifyWindowVisibility(bool visible) {
  if (push_channel_) {
    push_channel_->InvokeMethod(
        "onDesktopWindowVisibilityChanged",
        std::make_unique<flutter::EncodableValue>(visible));
  }
}

void FlutterWindow::ActivateWindow() {
  HWND handle = GetHandle();
  if (handle != nullptr) {
    const bool was_hidden = hidden_to_tray_ || !IsWindowVisible(handle);
    if (was_hidden) {
      ShowWindow(handle, SW_SHOW);
    }
    ShowWindow(handle, SW_RESTORE);
    SetForegroundWindow(handle);
    hidden_to_tray_ = false;
    if (was_hidden) NotifyWindowVisibility(true);
  }
}

void FlutterWindow::ActivateNotification() {
  ActivateWindow();
  if (push_channel_ && !notification_payload_.empty()) {
    push_channel_->InvokeMethod(
        "onNotificationOpened",
        std::make_unique<flutter::EncodableValue>(notification_payload_));
  }
  DismissWindowsNotification(notification_room_id_);
}

void FlutterWindow::ShowTrayMenu() {
  HWND handle = GetHandle();
  if (handle == nullptr) return;
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) return;
  AppendMenuW(menu, MF_STRING, kTrayOpenCommand, L"Открыть Orex");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayExitCommand, L"Выйти");
  POINT point{};
  GetCursorPos(&point);
  SetForegroundWindow(handle);
  TrackPopupMenu(menu, TPM_RIGHTBUTTON | TPM_BOTTOMALIGN | TPM_LEFTALIGN,
                 point.x, point.y, 0, handle, nullptr);
  PostMessageW(handle, WM_NULL, 0, 0);
  DestroyMenu(menu);
}

void FlutterWindow::RequestQuit() {
  HWND handle = GetHandle();
  if (handle != nullptr) {
    RemoveTrayIcon();
    DestroyWindow(handle);
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == WM_CLOSE ||
      (message == WM_SYSCOMMAND && (wparam & 0xFFF0) == SC_MINIMIZE) ||
      (message == WM_SIZE && wparam == SIZE_MINIMIZED)) {
    if (HideToTray()) return 0;
  }
  if (message == WM_COMMAND) {
    switch (LOWORD(wparam)) {
      case kTrayOpenCommand:
        ActivateWindow();
        return 0;
      case kTrayExitCommand:
        RequestQuit();
        return 0;
    }
  }
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    tray_icon_added_ = false;
    EnsureTrayIcon();
    return 0;
  }

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
    case kNotificationCallbackMessage: {
      const UINT event = LOWORD(static_cast<DWORD_PTR>(lparam));
      if (event == NIN_BALLOONUSERCLICK) {
        ActivateNotification();
      } else if (event == NIN_SELECT || event == NIN_KEYSELECT ||
                 event == WM_LBUTTONUP) {
        ActivateWindow();
      } else if (event == WM_RBUTTONUP || event == WM_CONTEXTMENU) {
        ShowTrayMenu();
      } else if (event == NIN_BALLOONHIDE || event == NIN_BALLOONTIMEOUT) {
        DismissWindowsNotification(notification_room_id_);
      }
      return 0;
    }
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
