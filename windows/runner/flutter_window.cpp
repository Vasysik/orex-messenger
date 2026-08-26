#include "flutter_window.h"

#include <windows.h>
#include <shellapi.h>
#include <mmdeviceapi.h>
#include <propvarutil.h>
#include <propsys.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <string>
#include <variant>
#include <vector>

#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <multiview_desktop/multi_view_desktop_plugin.h>

#include "orex_plugin_registrant.h"
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

#ifdef OREX_DEBUG_CHANNEL
constexpr const wchar_t kWindowStateRegKey[] =
    L"Software\\Orex\\MessengerDebug\\Window";
#else
constexpr const wchar_t kWindowStateRegKey[] =
    L"Software\\Orex\\Messenger\\Window";
#endif
constexpr const wchar_t kWindowStateLeft[] = L"Left";
constexpr const wchar_t kWindowStateTop[] = L"Top";
constexpr const wchar_t kWindowStateWidth[] = L"Width";
constexpr const wchar_t kWindowStateHeight[] = L"Height";
constexpr const wchar_t kWindowStateMaximized[] = L"Maximized";
constexpr const wchar_t kWindowStateMonitor[] = L"Monitor";

struct SavedWindowState {
  LONG left = 0;
  LONG top = 0;
  LONG width = 0;
  LONG height = 0;
  bool maximized = false;
  std::wstring monitor;
};

bool ReadRegistryDword(HKEY key, const wchar_t* name, DWORD* value) {
  DWORD size = sizeof(DWORD);
  return RegGetValueW(key, nullptr, name, RRF_RT_REG_DWORD, nullptr, value,
                      &size) == ERROR_SUCCESS;
}

bool ReadRegistryString(HKEY key, const wchar_t* name, std::wstring* value) {
  DWORD size = 0;
  if (RegGetValueW(key, nullptr, name, RRF_RT_REG_SZ, nullptr, nullptr,
                   &size) != ERROR_SUCCESS ||
      size < sizeof(wchar_t)) {
    return false;
  }
  std::vector<wchar_t> buffer(size / sizeof(wchar_t), L'\0');
  if (RegGetValueW(key, nullptr, name, RRF_RT_REG_SZ, nullptr, buffer.data(),
                   &size) != ERROR_SUCCESS) {
    return false;
  }
  *value = buffer.data();
  return true;
}

bool LoadSavedWindowState(SavedWindowState* state) {
  HKEY key = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kWindowStateRegKey, 0, KEY_QUERY_VALUE,
                    &key) != ERROR_SUCCESS) {
    return false;
  }

  DWORD left = 0;
  DWORD top = 0;
  DWORD width = 0;
  DWORD height = 0;
  DWORD maximized = 0;
  const bool complete =
      ReadRegistryDword(key, kWindowStateLeft, &left) &&
      ReadRegistryDword(key, kWindowStateTop, &top) &&
      ReadRegistryDword(key, kWindowStateWidth, &width) &&
      ReadRegistryDword(key, kWindowStateHeight, &height) &&
      ReadRegistryDword(key, kWindowStateMaximized, &maximized);
  if (complete) {
    ReadRegistryString(key, kWindowStateMonitor, &state->monitor);
    state->left = static_cast<LONG>(left);
    state->top = static_cast<LONG>(top);
    state->width = static_cast<LONG>(width);
    state->height = static_cast<LONG>(height);
    state->maximized = maximized != 0;
  }
  RegCloseKey(key);
  return complete && state->width >= 320 && state->height >= 240;
}

void WriteRegistryDword(HKEY key, const wchar_t* name, LONG value) {
  const DWORD raw = static_cast<DWORD>(value);
  RegSetValueExW(key, name, 0, REG_DWORD,
                 reinterpret_cast<const BYTE*>(&raw), sizeof(raw));
}

void SaveWindowStateToRegistry(const SavedWindowState& state) {
  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kWindowStateRegKey, 0, nullptr, 0,
                      KEY_SET_VALUE, nullptr, &key, nullptr) != ERROR_SUCCESS) {
    return;
  }
  WriteRegistryDword(key, kWindowStateLeft, state.left);
  WriteRegistryDword(key, kWindowStateTop, state.top);
  WriteRegistryDword(key, kWindowStateWidth, state.width);
  WriteRegistryDword(key, kWindowStateHeight, state.height);
  const DWORD maximized = state.maximized ? 1 : 0;
  RegSetValueExW(key, kWindowStateMaximized, 0, REG_DWORD,
                 reinterpret_cast<const BYTE*>(&maximized),
                 sizeof(maximized));
  const DWORD monitor_bytes = static_cast<DWORD>(
      (state.monitor.size() + 1) * sizeof(wchar_t));
  RegSetValueExW(key, kWindowStateMonitor, 0, REG_SZ,
                 reinterpret_cast<const BYTE*>(state.monitor.c_str()),
                 monitor_bytes);
  RegCloseKey(key);
}

struct MonitorLookup {
  std::wstring name;
  HMONITOR monitor = nullptr;
};

BOOL CALLBACK FindMonitorByName(HMONITOR monitor, HDC, LPRECT, LPARAM data) {
  auto* lookup = reinterpret_cast<MonitorLookup*>(data);
  MONITORINFOEXW info{};
  info.cbSize = sizeof(info);
  if (GetMonitorInfoW(monitor, &info) && lookup->name == info.szDevice) {
    lookup->monitor = monitor;
    return FALSE;
  }
  return TRUE;
}

HMONITOR MonitorForName(const std::wstring& name) {
  if (name.empty()) return nullptr;
  MonitorLookup lookup{name, nullptr};
  EnumDisplayMonitors(nullptr, nullptr, FindMonitorByName,
                      reinterpret_cast<LPARAM>(&lookup));
  return lookup.monitor;
}

std::wstring MonitorName(HMONITOR monitor) {
  if (monitor == nullptr) return std::wstring();
  MONITORINFOEXW info{};
  info.cbSize = sizeof(info);
  return GetMonitorInfoW(monitor, &info) ? info.szDevice : std::wstring();
}

RECT ClampWindowToWorkArea(RECT rect, HMONITOR preferred_monitor) {
  HMONITOR monitor = preferred_monitor;
  if (monitor == nullptr) {
    monitor = MonitorFromRect(&rect, MONITOR_DEFAULTTONEAREST);
  }
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  if (monitor == nullptr || !GetMonitorInfoW(monitor, &info)) return rect;

  const LONG work_width = std::max(1L, info.rcWork.right - info.rcWork.left);
  const LONG work_height = std::max(1L, info.rcWork.bottom - info.rcWork.top);
  const LONG min_width = std::min(320L, work_width);
  const LONG min_height = std::min(240L, work_height);
  LONG width = std::clamp(rect.right - rect.left, min_width, work_width);
  LONG height = std::clamp(rect.bottom - rect.top, min_height, work_height);
  LONG left = rect.left;
  LONG top = rect.top;

  if (left < info.rcWork.left) left = info.rcWork.left;
  if (top < info.rcWork.top) top = info.rcWork.top;
  if (left + width > info.rcWork.right) left = info.rcWork.right - width;
  if (top + height > info.rcWork.bottom) top = info.rcWork.bottom - height;

  return RECT{left, top, left + width, top + height};
}

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

int MapInt(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return 0;
  if (const auto* value = std::get_if<int32_t>(&it->second)) {
    return std::max(0, *value);
  }
  if (const auto* value = std::get_if<int64_t>(&it->second)) {
    return static_cast<int>(std::clamp<int64_t>(
        *value, 0, std::numeric_limits<int>::max()));
  }
  return 0;
}

HICON CreateBadgedTrayIcon(HICON base_icon) {
  if (base_icon == nullptr) return nullptr;
  const int width = std::max(16, GetSystemMetrics(SM_CXSMICON));
  const int height = std::max(16, GetSystemMetrics(SM_CYSMICON));

  BITMAPV5HEADER bitmap_info{};
  bitmap_info.bV5Size = sizeof(bitmap_info);
  bitmap_info.bV5Width = width;
  bitmap_info.bV5Height = -height;
  bitmap_info.bV5Planes = 1;
  bitmap_info.bV5BitCount = 32;
  bitmap_info.bV5Compression = BI_BITFIELDS;
  bitmap_info.bV5RedMask = 0x00FF0000;
  bitmap_info.bV5GreenMask = 0x0000FF00;
  bitmap_info.bV5BlueMask = 0x000000FF;
  bitmap_info.bV5AlphaMask = 0xFF000000;

  void* raw_pixels = nullptr;
  HDC screen = GetDC(nullptr);
  HBITMAP color = CreateDIBSection(
      screen, reinterpret_cast<BITMAPINFO*>(&bitmap_info), DIB_RGB_COLORS,
      &raw_pixels, nullptr, 0);
  HDC canvas = CreateCompatibleDC(screen);
  if (screen != nullptr) ReleaseDC(nullptr, screen);
  if (color == nullptr || raw_pixels == nullptr || canvas == nullptr) {
    if (canvas != nullptr) DeleteDC(canvas);
    if (color != nullptr) DeleteObject(color);
    return nullptr;
  }

  HGDIOBJ previous = SelectObject(canvas, color);
  std::memset(raw_pixels, 0,
              static_cast<size_t>(width) * height * sizeof(uint32_t));
  DrawIconEx(canvas, 0, 0, base_icon, width, height, 0, nullptr, DI_NORMAL);
  SelectObject(canvas, previous);
  DeleteDC(canvas);

  auto* pixels = static_cast<uint32_t*>(raw_pixels);
  const int radius = std::max(3, std::min(width, height) / 4);
  const int center_x = width - radius;
  const int center_y = height - radius;
  const int border_radius_squared = radius * radius;
  const int inner_radius = std::max(1, radius - 1);
  const int inner_radius_squared = inner_radius * inner_radius;
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      const int dx = x - center_x;
      const int dy = y - center_y;
      const int distance_squared = dx * dx + dy * dy;
      if (distance_squared > border_radius_squared) continue;
      pixels[y * width + x] = distance_squared > inner_radius_squared
                                  ? 0xFFFFFFFFu
                                  : 0xFFC47A44u;
    }
  }

  const size_t mask_stride = ((static_cast<size_t>(width) + 15) / 16) * 2;
  std::vector<BYTE> mask_pixels(mask_stride * height, 0);
  HBITMAP mask = CreateBitmap(width, height, 1, 1, mask_pixels.data());
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

std::wstring TrayTooltip(int unread_count) {
#ifdef OREX_DEBUG_CHANNEL
  std::wstring tooltip = L"Orex Messenger Debug";
#else
  std::wstring tooltip = L"Orex Messenger";
#endif
  if (unread_count > 0) {
    tooltip += L" \u2014 ";
    tooltip += std::to_wstring(unread_count);
    tooltip += L" \u043d\u0435\u043f\u0440\u043e\u0447\u0438\u0442\u0430\u043d\u043d\u044b\u0445";
  }
  return tooltip;
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
  const int width = frame.right - frame.left;
  const int height = frame.bottom - frame.top;

  MultiViewDesktopPrepareEngine(project_, GetHandle());
  FlutterDesktopEngineRef engine = MultiViewDesktopGetEngineRef();
  if (engine == nullptr) {
    return false;
  }

  // Register before the view is attached so a very fast first frame cannot be
  // missed. The callback runs later on the platform thread, after the window
  // state below has been restored.
  FlutterDesktopEngineSetNextFrameCallback(
      engine,
      [](void* user_data) {
        auto* self = static_cast<FlutterWindow*>(user_data);
        HWND handle = self->GetHandle();
        if (handle != nullptr) {
          ShowWindow(handle,
                     self->restore_maximized_ ? SW_SHOWMAXIMIZED
                                              : SW_SHOWNORMAL);
        }
      },
      this);

  MultiViewDesktopCreateMainView(GetHandle(), width, height);

  // multiview_desktop creates/registers its own plugin while attaching the
  // primary view. Register every other Orex plugin afterwards so plugins that
  // query their registrar's implicit view see the real main FlutterView.
  RegisterOrexPlugins(engine);

  const HWND flutter_hwnd =
      MultiViewDesktopGetFlutterHwnd(MultiViewDesktopGetMainViewId());
  if (flutter_hwnd == nullptr) {
    return false;
  }
  SetChildContent(flutter_hwnd);

  const auto runner_registrar_ref =
      FlutterDesktopEngineGetPluginRegistrar(engine, "OrexRunnerPlugin");
  auto* runner_registrar =
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(runner_registrar_ref);
  auto* messenger = runner_registrar->messenger();

  audio_devices_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "orex/audio_devices",
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
          messenger, "orex/push",
          &flutter::StandardMethodCodec::GetInstance());
  push_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto* arguments =
            call.arguments() == nullptr
                ? nullptr
                : std::get_if<flutter::EncodableMap>(call.arguments());
        if (call.method_name() == "showLocalMatrixNotification" ||
            call.method_name() == "showIncomingCallNotification") {
          if (arguments == nullptr) {
            result->Error("invalid_arguments", "Expected notification map");
            return;
          }
          ShowWindowsNotification(*arguments);
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (call.method_name() == "dismissLocalMatrixNotification") {
          if (arguments != nullptr) {
            DismissWindowsNotification(MapString(*arguments, "room_id"));
          }
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (call.method_name() == "dismissIncomingCallNotification") {
          if (arguments != nullptr) {
            DismissIncomingCallNotification(
                MapString(*arguments, "room_id"),
                MapString(*arguments, "event_id"));
          }
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (call.method_name() == "setTrayUnreadCount") {
          if (arguments != nullptr) {
            UpdateTrayUnreadCount(MapInt(*arguments, "count"));
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

  RestoreWindowState();

  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  // Keep one icon for the process lifetime. It is both the tray affordance and
  // the shell anchor for transient notification balloons.
  EnsureTrayIcon();

  return true;
}
void FlutterWindow::OnDestroy() {
  if (destroyed_) return;
  destroyed_ = true;
  notification_payload_.clear();
  notification_room_id_.clear();
  notification_event_id_.clear();
  notification_kind_.clear();
  RemoveTrayIcon();
  push_channel_ = nullptr;
  audio_devices_channel_ = nullptr;
  Win32Window::OnDestroy();
}

bool FlutterWindow::EnsureTrayIcon() {
  if (tray_icon_added_) return true;
  if (GetHandle() == nullptr) return false;

  if (tray_base_icon_ == nullptr) {
    tray_base_icon_ = static_cast<HICON>(LoadImageW(
        GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
        GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON),
        LR_DEFAULTCOLOR));
  }
  if (tray_base_icon_ == nullptr) return false;

  if (tray_badged_icon_ != nullptr) {
    DestroyIcon(tray_badged_icon_);
    tray_badged_icon_ = nullptr;
  }
  if (unread_count_ > 0) {
    tray_badged_icon_ = CreateBadgedTrayIcon(tray_base_icon_);
  }

  tray_icon_ = {};
  tray_icon_.cbSize = sizeof(NOTIFYICONDATAW);
  tray_icon_.hWnd = GetHandle();
  tray_icon_.uID = kNotificationIconId;
  tray_icon_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  tray_icon_.uCallbackMessage = kNotificationCallbackMessage;
  tray_icon_.hIcon = tray_badged_icon_ != nullptr ? tray_badged_icon_
                                                   : tray_base_icon_;
  const std::wstring tooltip = TrayTooltip(unread_count_);
  wcsncpy_s(tray_icon_.szTip, tooltip.c_str(), _TRUNCATE);
  tray_icon_added_ = Shell_NotifyIconW(NIM_ADD, &tray_icon_) == TRUE;
  if (tray_icon_added_) {
    tray_icon_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &tray_icon_);
  }
  return tray_icon_added_;
}

void FlutterWindow::RefreshTrayIcon() {
  if (tray_base_icon_ == nullptr) return;

  HICON next_badged_icon = nullptr;
  if (unread_count_ > 0) {
    next_badged_icon = CreateBadgedTrayIcon(tray_base_icon_);
  }
  const HICON previous_badged_icon = tray_badged_icon_;
  tray_badged_icon_ = next_badged_icon;
  tray_icon_.hIcon = tray_badged_icon_ != nullptr ? tray_badged_icon_
                                                   : tray_base_icon_;
  const std::wstring tooltip = TrayTooltip(unread_count_);
  wcsncpy_s(tray_icon_.szTip, tooltip.c_str(), _TRUNCATE);
  if (tray_icon_added_) {
    tray_icon_.uFlags = NIF_ICON | NIF_TIP;
    Shell_NotifyIconW(NIM_MODIFY, &tray_icon_);
  }
  // Shell_NotifyIcon copies the icon, so the previous generated handle can be
  // released only after the replacement has been submitted.
  if (previous_badged_icon != nullptr) {
    DestroyIcon(previous_badged_icon);
  }
}

void FlutterWindow::UpdateTrayUnreadCount(int unread_count) {
  const int normalized = std::max(0, unread_count);
  if (normalized == unread_count_) return;
  unread_count_ = normalized;
  if (!EnsureTrayIcon()) return;
  RefreshTrayIcon();
}

void FlutterWindow::RemoveTrayIcon() {
  if (tray_icon_added_) {
    Shell_NotifyIconW(NIM_DELETE, &tray_icon_);
    tray_icon_added_ = false;
  }
  ClearNotificationAvatarIcon();
  if (tray_badged_icon_ != nullptr) {
    DestroyIcon(tray_badged_icon_);
    tray_badged_icon_ = nullptr;
  }
  if (tray_base_icon_ != nullptr) {
    DestroyIcon(tray_base_icon_);
    tray_base_icon_ = nullptr;
  }
  tray_icon_.hIcon = nullptr;
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
  const std::string event_id = MapString(payload, "event_id");
  std::string kind = MapString(payload, "orex_kind");
  if (kind.empty()) kind = "matrix_event";
  const bool incoming_call = kind == "incoming_call";
  if (title.empty() || body.empty() || room_id.empty() ||
      GetHandle() == nullptr) {
    return;
  }
  if (!EnsureTrayIcon()) return;

  // A ringing call owns the transient shell surface until it is answered,
  // rejected or remotely dismissed. A later unread message must never replace
  // it with a stale conversation balloon.
  if (!incoming_call && notification_kind_ == "incoming_call") return;
  ClearCurrentNotification();

  const std::wstring wide_title = Utf8ToWide(title);
  const std::wstring wide_body = Utf8ToWide(body);
  notification_avatar_icon_ =
      LoadAvatarIcon(MapString(payload, "sender_avatar_path"));
  // A cold avatar cache must not turn an incoming call into the generic
  // Windows warning/exclamation glyph. Use a private copy of the Orex app icon
  // until Dart refreshes this same notification with the caller avatar.
  if (incoming_call && notification_avatar_icon_ == nullptr &&
      tray_base_icon_ != nullptr) {
    notification_avatar_icon_ = CopyIcon(tray_base_icon_);
  }
  tray_icon_.hBalloonIcon = notification_avatar_icon_;
  wcsncpy_s(tray_icon_.szInfoTitle, wide_title.c_str(), _TRUNCATE);
  wcsncpy_s(tray_icon_.szInfo, wide_body.c_str(), _TRUNCATE);
  const DWORD icon_flags =
      notification_avatar_icon_ != nullptr ? NIIF_USER | NIIF_LARGE_ICON
                                           : NIIF_INFO;
  tray_icon_.dwInfoFlags =
      icon_flags | (incoming_call ? 0 : NIIF_RESPECT_QUIET_TIME);
  tray_icon_.uFlags = NIF_INFO;
  if (Shell_NotifyIconW(NIM_MODIFY, &tray_icon_) != TRUE) {
    ClearNotificationAvatarIcon();
    return;
  }

  notification_payload_ = payload;
  notification_room_id_ = room_id;
  notification_event_id_ = event_id;
  notification_kind_ = kind;
}

void FlutterWindow::ClearCurrentNotification() {
  notification_payload_.clear();
  notification_room_id_.clear();
  notification_event_id_.clear();
  notification_kind_.clear();
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

void FlutterWindow::DismissWindowsNotification(const std::string& room_id) {
  if (notification_kind_ == "incoming_call") return;
  if (!room_id.empty() && room_id != notification_room_id_) return;
  ClearCurrentNotification();
}

void FlutterWindow::DismissIncomingCallNotification(
    const std::string& room_id, const std::string& event_id) {
  if (notification_kind_ != "incoming_call") return;
  if (!room_id.empty() && room_id != notification_room_id_) return;
  if (!event_id.empty() && !notification_event_id_.empty() &&
      event_id != notification_event_id_) {
    return;
  }
  ClearCurrentNotification();
}

bool FlutterWindow::HideToTray() {
  HWND handle = GetHandle();
  if (handle == nullptr || !EnsureTrayIcon()) return false;
  SaveWindowState();
  hidden_to_tray_ = true;
  ShowWindow(handle, SW_HIDE);
  NotifyWindowVisibility(false);
  return true;
}

void FlutterWindow::NotifyWindowVisibility(bool visible) {
  if (desktop_window_visible_ == visible) return;
  desktop_window_visible_ = visible;
  if (push_channel_) {
    push_channel_->InvokeMethod(
        "onDesktopWindowVisibilityChanged",
        std::make_unique<flutter::EncodableValue>(visible));
  }
}

void FlutterWindow::ActivateWindow() {
  HWND handle = GetHandle();
  if (handle != nullptr) {
    if (hidden_to_tray_ || !IsWindowVisible(handle)) {
      ShowWindow(handle, SW_SHOW);
    }
    if (IsIconic(handle)) {
      ShowWindow(handle, SW_RESTORE);
    }
    SetForegroundWindow(handle);
    hidden_to_tray_ = false;
    NotifyWindowVisibility(true);
  }
}

void FlutterWindow::ActivateNotification() {
  ActivateWindow();
  if (push_channel_ && !notification_payload_.empty()) {
    push_channel_->InvokeMethod(
        "onNotificationOpened",
        std::make_unique<flutter::EncodableValue>(notification_payload_));
  }
  ClearCurrentNotification();
}

void FlutterWindow::ShowTrayMenu() {
  HWND handle = GetHandle();
  if (handle == nullptr) return;
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) return;
  AppendMenuW(menu, MF_STRING, kTrayOpenCommand,
              L"\u041e\u0442\u043a\u0440\u044b\u0442\u044c Orex");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kTrayExitCommand,
              L"\u0412\u044b\u0439\u0442\u0438");
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
    SaveWindowState();
    RemoveTrayIcon();
    DestroyWindow(handle);
  }
}

void FlutterWindow::RestoreWindowState() {
  HWND handle = GetHandle();
  if (handle == nullptr) return;

  SavedWindowState saved;
  if (!LoadSavedWindowState(&saved)) {
    CaptureNormalWindowBounds();
    restore_maximized_ = false;
    window_state_ready_ = true;
    return;
  }

  HMONITOR target_monitor = MonitorForName(saved.monitor);
  if (target_monitor == nullptr) {
    const POINT primary_origin{0, 0};
    target_monitor = MonitorFromPoint(primary_origin, MONITOR_DEFAULTTOPRIMARY);
  }

  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  RECT restored{saved.left, saved.top, saved.left + saved.width,
                saved.top + saved.height};
  if (target_monitor != nullptr &&
      GetMonitorInfoW(target_monitor, &monitor_info)) {
    // Position is persisted relative to the selected monitor's work area so a
    // monitor can move in the virtual desktop without stranding the window.
    restored.left = monitor_info.rcWork.left + saved.left;
    restored.top = monitor_info.rcWork.top + saved.top;
    restored.right = restored.left + saved.width;
    restored.bottom = restored.top + saved.height;
  }
  restored = ClampWindowToWorkArea(restored, target_monitor);

  SetWindowPos(handle, nullptr, restored.left, restored.top,
               restored.right - restored.left, restored.bottom - restored.top,
               SWP_NOZORDER | SWP_NOACTIVATE);
  normal_window_bounds_ = restored;
  has_normal_window_bounds_ = true;
  restore_maximized_ = saved.maximized;
  window_was_maximized_ = saved.maximized;
  window_state_ready_ = true;
}

void FlutterWindow::CaptureNormalWindowBounds() {
  HWND handle = GetHandle();
  if (handle == nullptr || IsIconic(handle) || IsZoomed(handle)) return;
  RECT bounds{};
  if (!GetWindowRect(handle, &bounds)) return;
  normal_window_bounds_ = bounds;
  has_normal_window_bounds_ = true;
}

void FlutterWindow::SaveWindowState() {
  if (!window_state_ready_) return;
  HWND handle = GetHandle();
  if (handle == nullptr) return;

  if (!IsZoomed(handle) && !IsIconic(handle)) CaptureNormalWindowBounds();
  if (!has_normal_window_bounds_) return;

  HMONITOR monitor =
      MonitorFromRect(&normal_window_bounds_, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info{};
  monitor_info.cbSize = sizeof(monitor_info);
  if (monitor == nullptr || !GetMonitorInfoW(monitor, &monitor_info)) return;

  const RECT safe = ClampWindowToWorkArea(normal_window_bounds_, monitor);
  SavedWindowState state;
  state.left = safe.left - monitor_info.rcWork.left;
  state.top = safe.top - monitor_info.rcWork.top;
  state.width = safe.right - safe.left;
  state.height = safe.bottom - safe.top;
  state.maximized = IsZoomed(handle) != FALSE || window_was_maximized_;
  state.monitor = MonitorName(monitor);
  SaveWindowStateToRegistry(state);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // A close initiated by the user (title-bar X, Alt+F4 or the system menu)
  // arrives as SC_CLOSE. Keep that familiar action mapped to the tray.
  // Installers and Windows Restart Manager, on the other hand, send
  // WM_QUERYENDSESSION/WM_ENDSESSION or WM_CLOSE directly and must be able to
  // terminate the process instead of watching it disappear into the tray.
  if (message == WM_QUERYENDSESSION) {
    external_shutdown_requested_ = true;
    return TRUE;
  }
  if (message == WM_ENDSESSION) {
    if (wparam != FALSE) {
      RequestQuit();
      return 0;
    }
    external_shutdown_requested_ = false;
  }
  if (message == WM_EXITSIZEMOVE) {
    CaptureNormalWindowBounds();
    SaveWindowState();
  }
  if (message == WM_SYSCOMMAND &&
      (wparam & 0xFFF0) == SC_MAXIMIZE) {
    CaptureNormalWindowBounds();
  }
  if (message == WM_SYSCOMMAND &&
      (wparam & 0xFFF0) == SC_CLOSE) {
    if (external_shutdown_requested_) {
      RequestQuit();
    } else if (!HideToTray()) {
      RequestQuit();
    }
    return 0;
  }
  if (message == WM_CLOSE) {
    RequestQuit();
    return 0;
  }
  if (message == WM_SIZE) {
    if (wparam == SIZE_MINIMIZED) {
      hidden_to_tray_ = false;
      NotifyWindowVisibility(false);
    } else if (wparam == SIZE_RESTORED || wparam == SIZE_MAXIMIZED) {
      hidden_to_tray_ = false;
      NotifyWindowVisibility(true);
      if (window_state_ready_ && wparam == SIZE_MAXIMIZED) {
        window_was_maximized_ = true;
        SaveWindowState();
      } else if (window_state_ready_ && wparam == SIZE_RESTORED &&
                 window_was_maximized_) {
        window_was_maximized_ = false;
        CaptureNormalWindowBounds();
        SaveWindowState();
      }
    }
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

  // Give Flutter and multiview-aware plugins an opportunity to handle the
  // native message after Orex's tray/window ownership rules above.
  LRESULT flutter_result = 0;
  if (message == WM_FONTCHANGE) {
    FlutterDesktopEngineReloadSystemFonts(MultiViewDesktopGetEngineRef());
  }
  if (MultiViewDesktopHandleWindowProc(hwnd, message, wparam, lparam,
                                       &flutter_result)) {
    return flutter_result;
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
        // Shell timeout only removes the visual balloon. Keep an incoming call
        // as the current high-priority notification until call lifecycle code
        // explicitly dismisses it; ordinary message state can be released.
        DismissWindowsNotification(notification_room_id_);
      }
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
