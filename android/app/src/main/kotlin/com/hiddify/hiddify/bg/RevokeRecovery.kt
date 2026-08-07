package com.hiddify.hiddify.bg

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat
import com.hiddify.hiddify.Application
import com.hiddify.hiddify.MainActivity
import com.hiddify.hiddify.R
import com.hiddify.hiddify.Settings
import java.io.File

/// Реакция на onRevoke: Android держит только один активный VPN, и когда другое
/// VPN-приложение делает establish(), система молча отзывает наш туннель —
/// пользователь видел это как «VPN пропал сам по себе» (уведомление исчезает
/// без следа). Здесь два ответа на это:
///  1. Уведомление с причиной и кнопкой «Восстановить» (тап открывает
///     приложение — авто-реконнект на resume делает остальное).
///  2. Цепочка будильников: пока слот занят чужим VPN — ждём; как только
///     освободился (чужой туннель погас или вовсе не встал) — поднимаем свой
///     сервис сами, без участия пользователя.
/// Явная остановка кнопкой «Стоп»/из приложения отменяет всё это (см. вызовы
/// clear() в BoxService) — с сознательно включённым чужим VPN не воюем.
object RevokeRecovery {
    private const val TAG = "A/RevokeRecovery"
    private const val NOTIFICATION_CHANNEL = "vpn-revoked"
    private const val NOTIFICATION_ID = 11
    const val ACTION_TICK = "com.tutu4ka.vpn.action.REVOKE_RECOVERY"
    private const val CHECK_INTERVAL_MS = 60_000L

    // Слот занят чужим VPN дольше 12 часов — считаем это осознанным выбором
    // пользователя и перестаём проверять (уведомление остаётся).
    private const val GIVE_UP_AFTER_MS = 12 * 60 * 60 * 1000L

    private fun markerFile() = File(Settings.baseDir, "revoked.flag")

    private fun alarmPendingIntent(context: Context): PendingIntent =
        PendingIntent.getBroadcast(
            context, 0,
            Intent(context, RevokeRecoveryReceiver::class.java).setAction(ACTION_TICK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    fun onRevoked(context: Context) {
        try {
            markerFile().writeText(System.currentTimeMillis().toString())
        } catch (e: Exception) {
            Log.w(TAG, "revoked marker write failed", e)
        }
        showNotification(context)
        schedule(context)
        Log.w(TAG, "VPN-слот отобран другим приложением — ждём освобождения")
    }

    /// Любой явный старт или явная остановка сервиса гасит восстановление.
    fun clear(context: Context) {
        try {
            val f = markerFile()
            if (f.exists()) f.delete()
        } catch (_: Exception) {
        }
        try {
            (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager)
                .cancel(alarmPendingIntent(context))
        } catch (_: Exception) {
        }
        try {
            Application.notificationManager.cancel(NOTIFICATION_ID)
        } catch (_: Exception) {
        }
    }

    private fun schedule(context: Context) {
        try {
            (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager)
                .setAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    SystemClock.elapsedRealtime() + CHECK_INTERVAL_MS,
                    alarmPendingIntent(context),
                )
        } catch (e: Exception) {
            Log.w(TAG, "recovery schedule failed", e)
        }
    }

    fun tick(context: Context) {
        val marker = markerFile()
        if (!marker.exists()) return
        val revokedAt = try {
            marker.readText().trim().toLong()
        } catch (_: Exception) {
            System.currentTimeMillis()
        }
        if (System.currentTimeMillis() - revokedAt > GIVE_UP_AFTER_MS) {
            Log.i(TAG, "чужой VPN активен слишком долго — прекращаем попытки")
            try {
                marker.delete()
            } catch (_: Exception) {
            }
            return
        }

        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val anyVpn: Boolean
        val physical: Boolean
        try {
            var vpn = false
            var net = false
            cm.allNetworks.forEach { n ->
                val caps = cm.getNetworkCapabilities(n) ?: return@forEach
                if (caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) vpn = true
                else if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) net = true
            }
            anyVpn = vpn
            physical = net
        } catch (e: Exception) {
            Log.w(TAG, "connectivity check failed", e)
            schedule(context)
            return
        }

        if (anyVpn) {
            // Слот всё ещё занят (чужой туннель жив) — не воюем, ждём дальше.
            schedule(context)
            return
        }
        if (!physical) {
            // Сети нет вовсе (метро/полёт) — стартовать бессмысленно.
            schedule(context)
            return
        }

        Log.w(TAG, "VPN-слот свободен → восстанавливаем туннель")
        try {
            // Flutter в этой цепочке не участвует — ядро поднимает сам сервис
            // (тот же приём, что при START_STICKY-рестарте).
            Settings.startCoreAfterStartingService = true
            BoxService.start()
            // Маркер и уведомление снимет onStartCommand через clear(); если
            // старт не удался — следующий тик попробует снова.
        } catch (e: Exception) {
            Log.w(TAG, "recovery start failed", e)
        }
        schedule(context)
    }

    private fun showNotification(context: Context) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Application.notificationManager.createNotificationChannel(
                    NotificationChannel(
                        NOTIFICATION_CHANNEL, "VPN отключён",
                        NotificationManager.IMPORTANCE_HIGH,
                    )
                )
            }
            val openApp = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            val builder = NotificationCompat.Builder(context, NOTIFICATION_CHANNEL)
                .setSmallIcon(R.drawable.ic_launcher_foreground)
                .setContentTitle("VPN отключён")
                .setContentText("Другое VPN-приложение перехватило подключение. Верну соединение, как только оно освободит место.")
                .setStyle(
                    NotificationCompat.BigTextStyle().bigText(
                        "Другое VPN-приложение перехватило подключение — Android разрешает только один активный VPN. Верну соединение автоматически, как только оно освободит место, или нажмите «Восстановить»."
                    )
                )
                .setContentIntent(openApp)
                .addAction(0, "Восстановить", openApp)
                .setAutoCancel(true)
                .setOnlyAlertOnce(true)
            Application.notificationManager.notify(NOTIFICATION_ID, builder.build())
        } catch (e: Exception) {
            Log.w(TAG, "revoke notification failed", e)
        }
    }
}

class RevokeRecoveryReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != RevokeRecovery.ACTION_TICK) return
        RevokeRecovery.tick(context)
    }
}
