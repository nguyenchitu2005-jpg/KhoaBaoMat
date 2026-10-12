import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:khoabaomat/core/di/injection.dart';
import 'package:khoabaomat/features/device/domain/lock_status.dart';
import 'package:khoabaomat/main.dart';

void main() {
  setUpAll(configureDependencies);

  for (final dark in [false, true]) {
    testWidgets('màn hình Tìm khoá hiển thị đúng (${dark ? 'tối' : 'sáng'}, 360dp)', (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.platformBrightnessTestValue = dark ? Brightness.dark : Brightness.light;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

      await tester.pumpWidget(const KhoabaomatApp());

      expect(find.text('Tìm khoá'), findsNWidgets(2)); // tiêu đề + nút
      expect(find.text('Chưa tìm thấy khoá nào'), findsOneWidget);
      expect(tester.takeException(), isNull); // không tràn bố cục
    });
  }

  test('LockStatus đọc đúng payload STATUS của firmware', () {
    final s = LockStatus.fromPayload([1, 0, 0, 0, 122, 0, 0, 0, 3]);
    expect(s.unlocked, isTrue);
    expect(s.uptime, const Duration(seconds: 122));
    expect(s.unlockCount, 3);
    expect(s.pairedPhones, isNull); // firmware giai đoạn 1 chưa gửi

    final s2 = LockStatus.fromPayload([0, 0, 0, 0, 5, 0, 0, 0, 0, 2, 1]);
    expect(s2.pairedPhones, 2);
    expect(s2.pairingMode, isTrue);
  });
}
