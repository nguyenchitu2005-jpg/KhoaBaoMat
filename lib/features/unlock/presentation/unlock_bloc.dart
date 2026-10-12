import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../domain/unlock_with_biometric.dart';

sealed class UnlockEvent {
  const UnlockEvent();
}

final class UnlockPressed extends UnlockEvent {
  const UnlockPressed(this.lockId);
  final String lockId;
}

sealed class UnlockState extends Equatable {
  const UnlockState();
  @override
  List<Object?> get props => [];
}

final class UnlockIdle extends UnlockState {
  const UnlockIdle();
}

final class UnlockInProgress extends UnlockState {
  const UnlockInProgress(this.step);
  final UnlockStep step;
  @override
  List<Object?> get props => [step];
}

final class UnlockSucceeded extends UnlockState {
  const UnlockSucceeded();
}

final class UnlockFailed extends UnlockState {
  const UnlockFailed(this.message);
  final String message;
  @override
  List<Object?> get props => [message];
}

class UnlockBloc extends Bloc<UnlockEvent, UnlockState> {
  UnlockBloc(this._unlock) : super(const UnlockIdle()) {
    on<UnlockPressed>(_onPressed);
  }

  final UnlockWithBiometric _unlock;

  Future<void> _onPressed(UnlockPressed event, Emitter<UnlockState> emit) async {
    if (state is UnlockInProgress) return; // bấm liên tục không gửi 2 lệnh
    final result = await _unlock(event.lockId, onStep: (s) => emit(UnlockInProgress(s)));
    emit(switch (result) {
      UnlockSuccess() => const UnlockSucceeded(),
      UnlockFailure(:final reason) => UnlockFailed(reason),
    });
  }
}
