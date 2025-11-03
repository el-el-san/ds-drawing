import 'package:flutter/material.dart';
import 'app.dart';
import 'bootstrap/bootstrap.dart' as bootstrap;

void main(List<String> args) {
  WidgetsFlutterBinding.ensureInitialized();
  if (bootstrap.initializeDesktop(args)) {
    return;
  }
  runApp(const DirectDrawingApp());
}
