import 'package:flutter/foundation.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/app_trial/app_trial_service.dart';
import 'package:hiddify/features/app_trial/device_identity.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_mapper.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_sort_enum.dart';
import 'package:hiddify/features/settings/data/server_routing.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// Только в debug: sub_url и прочие детали подписки — это bearer-доступ к
// VPN-ключам, а debugPrint в release пишет их в системный лог устройства.
void _log(String msg) {
  if (kDebugMode) debugPrint('APP_TRIAL: $msg');
}

/// Ключ в SharedPreferences: id профиля, которым управляет автоподписка.
/// Нужен, чтобы не плодить дубли и знать, что мигрировать после привязки.
const _managedProfileKey = 'app_managed_profile_id';

/// Синхронизация встроенной подписки с бэкендом бота.
///
/// Дёргается при старте (watch на главном экране) и при возврате из фона
/// (invalidate в [App.onResume]). Идемпотентна:
///  - первый запуск → активирует триал по device_id и добавляет профиль;
///  - обычный запуск → перекачивает тот же профиль (свежие ключи и срок);
///  - после привязки к Telegram sub_url меняется (токен Telegram-юзера) →
///    мигрируем профиль: добавляем новый, удаляем старый — без дублей.
///
/// Возвращает ответ бэкенда для баннера подписки. null — если активацию
/// провести не удалось (нет сети и т.п.); тогда оставляем то, что уже есть.
final subscriptionSyncProvider = FutureProvider<AppTrialResult?>((ref) async {
  _log('sync started');

  final deviceId = await DeviceIdentity.deviceId();
  if (deviceId == null) {
    _log('no deviceId');
    return null;
  }

  final AppTrialResult result;
  try {
    result = await AppTrialService().activate(deviceId);
    _log('activate ok: status=${result.status} linked=${result.linked}');
  } catch (e) {
    _log('activate FAILED: $e');
    return null;
  }

  // Серверное правило «только зарубежный трафик» — сохраняем, чтобы применять
  // его, не завязываясь на версию приложения.
  if (result.routing != null) {
    try {
      await saveForeignRouting(ref, result.routing!);
    } catch (e) {
      _log('save routing failed: $e');
    }
  }

  final subUrl = result.subUrl;
  if (subUrl == null || subUrl.isEmpty) {
    _log('no sub_url in response');
    return result;
  }

  // КРИТИЧНО: не трогаем профиль, пока VPN активен. Замена/обновление активного
  // профиля на живом туннеле заставляет ядро переподнимать TUN и падает с
  // "configure tun interface: permission denied". Если туннель поднят или
  // переключается — обновляем только баннер; миграция/refresh выполнятся при
  // следующем синке, когда VPN будет отключён (см. listener в App.build).
  final connStatus = ref.read(connectionNotifierProvider).valueOrNull;
  final tunnelActive = connStatus != null && !connStatus.isDisconnected;
  if (tunnelActive) {
    _log('tunnel active ($connStatus) → defer profile sync, banner only');
    return result;
  }

  try {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final repo = await ref.read(profileRepositoryProvider.future);
    final dataSource = ref.read(profileDataSourceProvider);

    // текущий управляемый профиль (если был)
    final managedId = prefs.getString(_managedProfileKey);
    ProfileEntity? managed;
    if (managedId != null) {
      managed = (await repo.getById(managedId).run()).getOrElse((_) => null);
    }

    final sameUrl = managed is RemoteProfileEntity && managed.url == subUrl;

    // upsertRemote сам решает: обновить существующий по URL или добавить новый.
    // В обоих случаях прогоняется фильтр RU и тянутся свежие ключи/срок.
    final either = await repo
        .upsertRemote(subUrl, userOverride: const UserOverride(name: Constants.appName))
        .run();
    either.match(
      (f) => _log('upsertRemote FAILED: $f'),
      (_) => _log('upsertRemote OK'),
    );

    if (!sameUrl) {
      // новый профиль или миграция (после привязки сменился токен)
      final newProfile = (await dataSource.getByUrl(subUrl))?.toEntity();
      if (newProfile != null) {
        // Сначала удаляем старый профиль — чтобы при обрыве (invalidate между
        // setString и deleteById) старый не оставался висеть «призраком».
        if (managed != null && managed.id != newProfile.id) {
          await repo.deleteById(managed.id, false).run();
          _log('deleted old managed profile ${managed.id}');
        }
        await prefs.setString(_managedProfileKey, newProfile.id);
        await repo.setAsActive(newProfile.id).run();
        _log('migrated profile ${managed?.id} -> ${newProfile.id}');
      }
    }

    // Чистим «призраки»: любые профили с именем приложения, кроме текущего
    // управляемого (накопились из-за прерванных синков или старых версий кода).
    final currentManagedId = prefs.getString(_managedProfileKey);
    if (currentManagedId != null) {
      final allProfiles = await dataSource
          .watchAll(sort: ProfilesSort.lastUpdate, sortMode: SortMode.ascending)
          .first;
      for (final entry in allProfiles) {
        if (entry.id != currentManagedId &&
            entry.name.startsWith(Constants.appName)) {
          await repo.deleteById(entry.id, false).run();
          _log('cleaned up orphaned profile ${entry.id} (${entry.name})');
        }
      }
    }
  } catch (e) {
    _log('profile sync error: $e');
  }

  return result;
});
