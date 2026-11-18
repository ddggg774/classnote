// lib/main.dart
// App 入口：初始化 Flutter、锁定竖屏、加载首页。
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'pages/home_page.dart';

void main() async {
  // 保证 Flutter 引擎初始化完成（后续会用到数据库等插件）
  WidgetsFlutterBinding.ensureInitialized();

  // 锁定竖屏：课堂记录场景竖屏更自然
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  runApp(const ClassNoteApp());
}

class ClassNoteApp extends StatelessWidget {
  const ClassNoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '课堂笔记',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
