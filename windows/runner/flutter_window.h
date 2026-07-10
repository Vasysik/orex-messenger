#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

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
  void ShowWindowsNotification(const flutter::EncodableMap& payload);
  void DismissWindowsNotification(const std::string& room_id);
  void ActivateNotification();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      audio_devices_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> push_channel_;
  NOTIFYICONDATAW notification_icon_{};
  flutter::EncodableMap notification_payload_;
  std::string notification_room_id_;
  bool notification_icon_added_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
