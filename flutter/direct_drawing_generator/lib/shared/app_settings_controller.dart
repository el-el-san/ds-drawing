import 'package:flutter/foundation.dart';

import '../features/drawing/models/app_settings.dart';
import '../features/drawing/services/settings_repository.dart';

class AppSettingsController extends ChangeNotifier {
  AppSettingsController({SettingsRepository? repository})
      : _repository = repository ?? SettingsRepository();

  final SettingsRepository _repository;
  bool _initialized = false;
  Future<void>? _initializing;
  AppSettings _settings = AppSettings.defaults();

  bool get isInitialized => _initialized;
  AppSettings get settings => _settings;

  Future<void> init() async {
    if (_initialized) {
      return;
    }
    if (_initializing != null) {
      await _initializing;
      return;
    }
    _initializing = _load();
    try {
      await _initializing;
    } finally {
      _initializing = null;
    }
  }

  Future<void> update(AppSettings newSettings) async {
    _settings = newSettings;
    await _repository.save(newSettings);
    _initialized = true;
    notifyListeners();
  }

  Future<void> reset() async {
    await update(AppSettings.defaults());
  }

  Future<void> _load() async {
    _settings = await _repository.load();
    _initialized = true;
    notifyListeners();
  }
}
