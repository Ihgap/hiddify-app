import 'package:flutter/foundation.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/features/app_trial/app_trial_service.dart';
import 'package:hiddify/features/app_trial/device_identity.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void _log(String msg) => debugPrint('APP_TRIAL: $msg');

/// Автоактивация встроенной подписки при первом запуске.
///
/// Логика: если в приложении ещё нет ни одного профиля — спросить у бэкенда
/// подписку по device_id и добавить её как активный профиль. Состояние триала
/// (выдавать ли новые 7 дней) решает сервер, не приложение, — это и закрывает
/// "удалил-поставил заново". Запускается при сборке домашнего экрана.
final appTrialControllerProvider = FutureProvider.autoDispose<AppTrialResult?>((ref) async {
  _log('controller started');

  final hasAny = await ref.watch(hasAnyProfileProvider.future);
  _log('hasAnyProfile = $hasAny');
  if (hasAny) return null;

  final deviceId = await DeviceIdentity.androidId();
  _log('androidId = $deviceId');
  if (deviceId == null) return null;

  final AppTrialResult result;
  try {
    result = await AppTrialService().activate(deviceId);
    _log('activate ok: status=${result.status} sub=${result.subUrl}');
  } catch (e) {
    _log('activate FAILED: $e');
    rethrow;
  }

  final subUrl = result.subUrl;
  if (subUrl == null || subUrl.isEmpty) {
    _log('no sub_url in response');
    return result;
  }

  final repo = await ref.read(profileRepositoryProvider.future);
  final either = await repo
      .upsertRemote(subUrl, userOverride: const UserOverride(name: Constants.appName))
      .run();
  either.match(
    (f) => _log('upsertRemote FAILED: $f'),
    (_) => _log('profile added OK'),
  );

  return result;
});
