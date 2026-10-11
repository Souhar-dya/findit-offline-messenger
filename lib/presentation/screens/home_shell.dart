import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../controllers/chats_controller.dart';
import '../controllers/friends_controller.dart';
import '../controllers/nearby_controller.dart';
import '../controllers/settings_controller.dart';
import 'chats_screen.dart';
import 'friends_screen.dart';
import 'nearby_screen.dart';
import 'profile_screen.dart';

/// The authenticated shell with the four primary tabs.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  static const List<String> _titles = ['Chats', 'Friends', 'Nearby', 'Profile'];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshCurrent());
  }

  void _refreshCurrent() {
    switch (_index) {
      case 0:
        context.read<ChatsController>().refresh();
      case 1:
        context.read<FriendsController>().refresh();
      case 2:
        context.read<NearbyController>().refresh();
      case 3:
        context.read<SettingsController>().refresh();
    }
  }

  void _select(int index) {
    setState(() => _index = index);
    _refreshCurrent();
  }

  @override
  Widget build(BuildContext context) {
    final screens = const [
      ChatsScreen(),
      FriendsScreen(),
      NearbyScreen(),
      ProfileScreen(),
    ];
    return Scaffold(
      appBar: AppBar(title: Text(_titles[_index])),
      body: IndexedStack(index: _index, children: screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _select,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chats',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: 'Friends',
          ),
          NavigationDestination(
            icon: Icon(Icons.wifi_tethering),
            label: 'Nearby',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: 'Profile',
          ),
        ],
      ),
    );
  }
}
