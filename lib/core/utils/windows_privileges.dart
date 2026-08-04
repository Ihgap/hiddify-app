import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Права администратора текущего процесса (Windows).
///
/// Нужны режиму «VPN»: TUN-интерфейс создаётся только с ними, иначе ядро
/// падает на старте, а сообщение о причине теряется по дороге к пользователю.
/// На остальных платформах вызывать не нужно — там туннель поднимает система.
bool isWindowsElevated() {
  if (!Platform.isWindows) return false;

  final pToken = calloc<IntPtr>();
  final pElevated = calloc<Uint32>();
  final pReturned = calloc<Uint32>();
  try {
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, pToken) == 0) return false;
    try {
      final ok = GetTokenInformation(pToken.value, TokenElevation, pElevated, sizeOf<Uint32>(), pReturned);
      return ok != 0 && pElevated.value != 0;
    } finally {
      CloseHandle(pToken.value);
    }
  } catch (_) {
    return false;
  } finally {
    calloc
      ..free(pToken)
      ..free(pElevated)
      ..free(pReturned);
  }
}

/// Запускает копию приложения с запросом UAC.
///
/// true — система приняла запуск (окно UAC показано и подтверждено). false —
/// пользователь отказал или запуск не удался; вызывающий остаётся как есть.
///
/// Вызвавший ОБЯЗАН сразу завершить текущий процесс: ядро слушает фиксированные
/// порты, и если старый процесс переживёт новый старт, новый экземпляр найдёт
/// уже поднятое ядро (`core is already started!`) и снова окажется без прав.
bool relaunchAsAdmin() {
  if (!Platform.isWindows) return false;

  final exe = Platform.resolvedExecutable;
  final verb = 'runas'.toNativeUtf16();
  final file = exe.toNativeUtf16();
  final dir = File(exe).parent.path.toNativeUtf16();
  try {
    // ShellExecute возвращает >32 при успехе; 5 (ERROR_ACCESS_DENIED) — отказ в UAC.
    return ShellExecute(0, verb, file, nullptr, dir, SW_SHOWNORMAL) > 32;
  } catch (_) {
    return false;
  } finally {
    calloc
      ..free(verb)
      ..free(file)
      ..free(dir);
  }
}
