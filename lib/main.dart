// lib/main.dart
// App 入口：初始化 Flutter、锁定竖屏、加载首页。
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'pages/disclaimer_page.dart';
import 'pages/home_page.dart';
import 'services/settings_service.dart';

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
      home: const StartupGate(),
    );
  }
}

/// 启动闸门：没同意免责声明就不给进首页。
///
/// 【为什么放在入口而不是设置里】
/// 这个 App 会录课堂声音、把内容发给第三方模型。用户必须在第一次使用前
/// 明确看到这些条款并点同意；藏在设置里等于没有告知。
class StartupGate extends StatefulWidget {
  const StartupGate({super.key});

  @override
  State<StartupGate> createState() => _StartupGateState();
}

class _StartupGateState extends State<StartupGate> {
  /// null = 还在读本地记录
  bool? _accepted;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final ok =
        await SettingsService().hasAcceptedDisclaimer(Disclaimer.version);
    if (!mounted) return;
    setState(() => _accepted = ok);
  }

  @override
  Widget build(BuildContext context) {
    final accepted = _accepted;
    if (accepted == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (accepted) return const HomePage();
    return DisclaimerPage(
      onAccepted: () => setState(() => _accepted = true),
    );
  }
}
