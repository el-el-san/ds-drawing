import 'package:desktop_webview_window/desktop_webview_window.dart';
import 'package:media_kit/media_kit.dart';
import 'package:universal_io/io.dart';

bool initializeDesktop(List<String> args) {
  if (!Platform.isWindows) {
    return false;
  }

  if (runWebViewTitleBarWidget(args)) {
    return true;
  }

  MediaKit.ensureInitialized();
  return false;
}
