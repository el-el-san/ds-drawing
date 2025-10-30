import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../shared/app_settings_controller.dart';
import '../drawing/drawing_page.dart';
import '../settings/settings_page.dart';
import '../story/story_controller.dart';
import '../story/story_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  static const int _tabCount = 3;
  late final AppSettingsController _settingsController;
  late final StoryController _storyController;

  @override
  void initState() {
    super.initState();
    _settingsController = AppSettingsController();
    _storyController = StoryController(settingsController: _settingsController);
  }

  @override
  void dispose() {
    _storyController.dispose();
    _settingsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AppSettingsController>.value(value: _settingsController),
        ChangeNotifierProvider<StoryController>.value(value: _storyController),
      ],
      child: DefaultTabController(
        length: _tabCount,
        child: Scaffold(
          backgroundColor: const Color(0xff0f141b),
          body: TabBarView(
            physics: const NeverScrollableScrollPhysics(),
            children: <Widget>[
              DrawingPage(settingsController: _settingsController),
              const StoryPage(),
              const SettingsPage(),
            ],
          ),
          bottomNavigationBar: const Material(
            color: Color(0xff1b2430),
            child: SizedBox(
              height: 64,
              child: TabBar(
                indicatorColor: Color(0xff4a9eff),
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white54,
                tabs: <Tab>[
                  Tab(icon: Icon(Icons.brush), text: 'Drawing'),
                  Tab(icon: Icon(Icons.movie_filter), text: 'Story'),
                  Tab(icon: Icon(Icons.settings), text: 'Settings'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
