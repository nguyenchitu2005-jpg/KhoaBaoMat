import 'package:flutter/material.dart';

import 'core/di/injection.dart';
import 'core/storage/lock_key_store.dart';
import 'core/theme/app_theme.dart';
import 'features/device/presentation/scan_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  configureDependencies();
  await sl<LockKeyStore>().purgeDemoKeys(); // khoá thử nghiệm toàn số 0 của giai đoạn 1 không còn dùng được
  runApp(const KhoabaomatApp());
}

class KhoabaomatApp extends StatelessWidget {
  const KhoabaomatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Khoá bảo mật',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const ScanPage(),
    );
  }
}
