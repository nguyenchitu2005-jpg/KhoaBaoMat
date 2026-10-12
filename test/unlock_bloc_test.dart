import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:khoabaomat/features/unlock/domain/unlock_with_biometric.dart';
import 'package:khoabaomat/features/unlock/presentation/unlock_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockUnlock extends Mock implements UnlockWithBiometric {}

void main() {
  late MockUnlock unlock;
  setUp(() => unlock = MockUnlock());

  blocTest<UnlockBloc, UnlockState>(
    'mở thành công: xác thực → gửi → thành công',
    build: () {
      when(() => unlock(any(), onStep: any(named: 'onStep'))).thenAnswer((inv) async {
        final onStep = inv.namedArguments[#onStep] as void Function(UnlockStep);
        UnlockStep.values.forEach(onStep);
        return const UnlockSuccess();
      });
      return UnlockBloc(unlock);
    },
    act: (b) => b.add(const UnlockPressed('AA:BB:CC:DD:EE:FF')),
    expect: () => const [
      UnlockInProgress(UnlockStep.authenticating),
      UnlockInProgress(UnlockStep.sending),
      UnlockSucceeded(),
    ],
  );

  blocTest<UnlockBloc, UnlockState>(
    'huỷ quét khuôn mặt thì báo lỗi, không gửi lệnh',
    build: () {
      when(() => unlock(any(), onStep: any(named: 'onStep')))
          .thenAnswer((_) async => const UnlockFailure('Đã huỷ xác thực'));
      return UnlockBloc(unlock);
    },
    act: (b) => b.add(const UnlockPressed('AA:BB:CC:DD:EE:FF')),
    expect: () => const [UnlockFailed('Đã huỷ xác thực')],
  );
}
