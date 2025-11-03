import 'package:flutter/material.dart';

import '../../shared/app_settings_controller.dart';

class StoryController extends ChangeNotifier {
  StoryController({required AppSettingsController settingsController});

  bool get isInitialized => true;

  Future<void> init() async {}

  Future<String?> refreshUploadAuthorization(BuildContext context) async {
    return 'Story mode is unavailable on the web build.';
  }

  Future<String?> ensureUploadAuthorization(
    BuildContext context, {
    bool forceRefresh = false,
  }) async {
    return 'Story mode is unavailable on the web build.';
  }

  @override
  void dispose() {
    super.dispose();
  }
}
