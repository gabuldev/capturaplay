import 'package:flutter/material.dart';

import 'studio_controller.dart';
import 'theme.dart';
import 'ui/player_page.dart';

class CapturaPlayApp extends StatefulWidget {
  const CapturaPlayApp({super.key, required this.controller});

  final StudioController controller;

  @override
  State<CapturaPlayApp> createState() => _CapturaPlayAppState();
}

class _CapturaPlayAppState extends State<CapturaPlayApp> {
  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CapturaPlay',
      debugShowCheckedModeBanner: false,
      theme: capturaTheme(),
      home: PlayerPage(controller: widget.controller),
    );
  }
}
