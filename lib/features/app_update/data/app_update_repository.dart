import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/core/utils/exception_handler.dart';
import 'package:hiddify/features/app_update/model/app_update_failure.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:upgrader/upgrader.dart';

/// pubDate в appcast — формат RFC-822, DateTime.parse его не берёт. Дата нужна
/// только для показа, поэтому при неудаче не падаем.
DateTime _parsePubDate(String? value) {
  if (value == null || value.isEmpty) return DateTime.now();
  return DateTime.tryParse(value) ?? DateTime.now();
}

abstract interface class AppUpdateRepository {
  TaskEither<AppUpdateFailure, RemoteVersionEntity> getLatestVersion({
    bool includePreReleases = false,
    Release release = Release.general,
  });
}

class AppUpdateRepositoryImpl with ExceptionHandler, InfraLogger implements AppUpdateRepository {
  AppUpdateRepositoryImpl({required this.httpClient});

  final DioHttpClient httpClient;

  @override
  TaskEither<AppUpdateFailure, RemoteVersionEntity> getLatestVersion({
    bool includePreReleases = false,
    Release release = Release.general,
  }) {
    return exceptionHandler(() async {
      if (!release.allowCustomUpdateChecker) {
        throw Exception("custom update checkers are not supported");
      }

      // Источник — тот же appcast, что и у автоматической проверки
      // (UpgradeAlert). Раньше здесь был GitHub Releases: релизов там нет,
      // firstWhere кидал StateError, и кнопка «Проверить обновления» всегда
      // возвращала ошибку. Две разные правды про версию заодно расходились.
      final appcast = Appcast();
      final items = await appcast.parseAppcastItemsFromUri(Constants.appCastUrl);
      if (items == null || items.isEmpty) {
        loggy.warning("appcast is empty or could not be fetched: ${Constants.appCastUrl}");
        return left(const AppUpdateFailure.unexpected());
      }

      // bestItem отбирает записи по текущей ОС (sparkle:os) и берёт старшую версию.
      final best = appcast.bestItem();
      final version = best?.versionString;
      if (best == null || version == null || version.isEmpty) {
        loggy.warning("appcast has no item for this platform (${appcast.upgraderOS.current})");
        return left(const AppUpdateFailure.unexpected());
      }

      return right(
        RemoteVersionEntity(
          version: version,
          buildNumber: "",
          releaseTag: "v$version",
          preRelease: false,
          url: best.fileURL ?? Constants.appCastUrl,
          publishedAt: _parsePubDate(best.dateString),
          flavor: Environment.prod,
        ),
      );
    }, AppUpdateFailure.unexpected);
  }
}
