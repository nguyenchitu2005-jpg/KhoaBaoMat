import 'package:get_it/get_it.dart';

import '../../features/access/domain/access_admin.dart';
import '../../features/biometric/data/biometric_auth_service.dart';
import '../../features/device/data/ble_lock_data_source.dart';
import '../../features/device/domain/lock_status.dart';
import '../../features/device/domain/pair_lock.dart';
import '../../features/device/presentation/device_cubit.dart';
import '../../features/device/presentation/pairing_cubit.dart';
import '../../features/device/presentation/scan_cubit.dart';
import '../../features/unlock/domain/unlock_with_biometric.dart';
import '../../features/unlock/presentation/unlock_bloc.dart';
import '../ble/secure_command_sender.dart';
import '../crypto/lock_crypto.dart';
import '../storage/lock_key_store.dart';

final sl = GetIt.instance;

/// Gọi 1 lần trong main() trước runApp().
void configureDependencies() {
  if (sl.isRegistered<BleLockDataSource>()) return;
  sl
    // data / core
    ..registerLazySingleton(BleLockDataSource.new)
    ..registerLazySingleton(BiometricAuthService.new)
    ..registerLazySingleton(LockKeyStore.new)
    ..registerLazySingleton(LockCrypto.new)
    ..registerLazySingleton(() => SecureCommandSender(sl(), sl(), sl()))
    // domain
    ..registerFactory(() => UnlockWithBiometric(sl(), sl(), sl()))
    ..registerFactory(() => ReadLockStatus(sl(), sl()))
    ..registerFactory(() => LockNow(sl(), sl()))
    ..registerFactory(() => PairLock(sl(), sl(), sl()))
    ..registerFactory(() => AccessAdmin(sl(), sl(), sl()))
    // presentation
    ..registerFactory(() => ScanCubit(sl()))
    ..registerFactory(() => DeviceCubit(sl(), sl(), sl(), sl()))
    ..registerFactory(() => PairingCubit(sl(), sl()))
    ..registerFactory(() => UnlockBloc(sl()));
}
