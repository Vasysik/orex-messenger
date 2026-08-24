#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

// shellapi.h depends on the core Win32 declarations/macros from windows.h.
// Do not rely on Flutter wrapper headers to include windows.h transitively: v21
// no longer owns a FlutterViewController, so that accidental include disappeared.
#include <windows.h>
#include <shellapi.h>
#include <memory>
#include <string>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  bool EnsureTrayIcon();
  void RefreshTrayIcon();
  void UpdateTrayUnreadCount(int unread_count);
  void RemoveTrayIcon();
  void ShowWindowsNotification(const flutter::EncodableMap& payload);
  void ClearCurrentNotification();
  void DismissWindowsNotification(const std::string& room_id);
  void DismissIncomingCallNotification(const std::string& room_id,
                                       const std::string& event_id);
  void ClearNotificationAvatarIcon();
  bool HideToTray();
  void NotifyWindowVisibility(bool visible);
  void ActivateWindow();
  void ActivateNotification();
  void ShowTrayMenu();
  void RequestQuit();
  void RestoreWindowState();
  void CaptureNormalWindowBounds();
  void SaveWindowState();

  // The project to run.
  flutter::DartProject project_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      audio_devices_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> push_channel_;
  NOTIFYICONDATAW tray_icon_{};
  flutter::EncodableMap notification_payload_;
  std::string notification_room_id_;
  std::string notification_event_id_;
  std::string notification_kind_;
  HICON tray_base_icon_ = nullptr;
  HICON tray_badged_icon_ = nullptr;
  HICON notification_avatar_icon_ = nullptr;
  UINT taskbar_created_message_ = 0;
  int unread_count_ = 0;
  bool tray_icon_added_ = false;
  bool hidden_to_tray_ = false;
  bool desktop_window_visible_ = true;
  bool external_shutdown_requested_ = false;
  bool destroyed_ = false;
  bool window_state_ready_ = false;
  bool restore_maximized_ = false;
  bool window_was_maximized_ = false;
  bool has_normal_window_bounds_ = false;
  RECT normal_window_bounds_{};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
