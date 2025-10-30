import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'package:desktop_webview_window/desktop_webview_window.dart';

import 'app.dart';

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    if (runWebViewTitleBarWidget(args)) {
      return;
    }
    MediaKit.ensureInitialized();
  }
  runApp(const DirectDrawingApp());
}
