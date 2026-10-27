#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>

#include <memory>
#include <string>
#include <vector>

#include "win32_window.h"

class FlutterWindow : public Win32Window {
 public:

  explicit FlutterWindow(const flutter::DartProject& project, bool start_hidden = false);
  virtual ~FlutterWindow();

 protected:

  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:

  flutter::DartProject project_;

  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  bool dart_ready_ = false;
  bool closing_ = false;
  bool allow_close_ = false;
  bool tray_added_ = false;
  bool start_hidden_ = false;
  bool custom_frame_ = false;
  bool max_hovered_ = false;
  bool max_pressed_ = false;
  struct TitlebarRect { double x, y, width, height; };
  std::vector<TitlebarRect> drag_regions_;
  TitlebarRect maximize_region_{};
  std::wstring tray_tooltip_ = L"SVOI";
  flutter::EncodableList tray_items_;
  bool UpdateTray();
  void RestoreFromTray();
  LRESULT FrameHitTest(LPARAM position);
  void CaptionHover(bool hovered);
  static LRESULT CALLBACK ChildFrameProc(HWND hwnd, UINT message, WPARAM wparam,
      LPARAM lparam, UINT_PTR id, DWORD_PTR context);
};

#endif
