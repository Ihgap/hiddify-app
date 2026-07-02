package com.hiddify.hiddify.bg

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log
import android.widget.RemoteViews
import androidx.annotation.StringRes
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.lifecycle.MutableLiveData
import com.hiddify.core.api.v2.config.Protocol
import com.hiddify.core.api.v2.hcommon.Empty
import com.hiddify.core.api.v2.hcore.CoreClient
import com.hiddify.core.api.v2.hcore.SystemInfo
import com.hiddify.core.api.v2.hello.HelloClient
import com.hiddify.core.api.v2.hello.HelloRequest
import com.hiddify.hiddify.Application
import com.hiddify.hiddify.MainActivity
import com.hiddify.hiddify.R
import com.hiddify.hiddify.Settings
import com.hiddify.hiddify.constant.Action
import com.hiddify.hiddify.constant.Status
//import com.hiddify.hiddify.utils.CommandClient
import com.hiddify.core.libbox.Libbox
import com.hiddify.hiddify.Application.Companion.notification
import com.hiddify.hiddify.utils.GrpcClientProvider
import com.squareup.wire.GrpcClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.isActive

import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.channels.SendChannel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import java.io.IOException
import kotlinx.coroutines.delay
import kotlinx.coroutines.CancellationException
class ServiceNotification(private val status: MutableLiveData<Status>, private val service: Service) : BroadcastReceiver(){
    companion object {
        private const val notificationId = 1
        // Новый id канала, чтобы новая важность (DEFAULT) применилась и на уже
        // установленных устройствах (важность существующего канала Android менять
        // не даёт).
        private const val notificationChannel = "vpn-service"
        var coreClient: CoreClient?=null
        val flags =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0

        fun checkPermission(): Boolean {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                return true
            }
            return Application.notification.areNotificationsEnabled()
        }
    }
    val streamingCoroutineScope = CoroutineScope(Dispatchers.IO + SupervisorJob())


//
//    private val commandClient =
//            CommandClient(GlobalScope, CommandClient.ConnectionType.Status, this)
    private var receiverRegistered = false


    private fun broadcastIntent(action: String) = PendingIntent.getBroadcast(
        service,
        0,
        Intent(action).setPackage(Application.application.packageName),
        flags
    )

    private val stopPendingIntent by lazy { broadcastIntent(Action.SERVICE_CLOSE) }
    private val pausePendingIntent by lazy { broadcastIntent(Action.SERVICE_PAUSE) }
    private val resumePendingIntent by lazy { broadcastIntent(Action.SERVICE_RESUME) }

    // Состояние «на паузе» и последний показанный текст — чтобы перерисовать
    // уведомление при нажатии «Пауза»/«Возобновить».
    private var paused = false
    private var lastTitle = ""
    private var lastText = ""

    fun setPaused(value: Boolean) {
        paused = value
        // На паузе ядро остановлено — поллинг GetSystemInfo всё равно отвалится,
        // поэтому останавливаем его сами (иначе спамит ошибками раз в секунду).
        if (value) stopListenSystemInfo()
        Application.notificationManager.notify(
            notificationId,
            notificationBuilder
                .setCustomContentView(buildContentView(R.layout.notification_vpn, lastTitle, lastText))
                .setCustomBigContentView(buildContentView(R.layout.notification_vpn_big, lastTitle, lastText))
                .build()
        )
    }

    // Кастомный вид уведомления со «Стоп» прямо в макете — чтобы кнопка была
    // видна в СВЁРНУТОМ уведомлении, без необходимости его разворачивать
    // (обычный addAction показывается только в развёрнутом виде).
    private fun buildContentView(layout: Int, title: String, text: String): RemoteViews {
        lastTitle = title
        lastText = text
        val rv = RemoteViews(service.packageName, layout)
        rv.setTextViewText(R.id.notif_title, title.takeIf { it.isNotBlank() } ?: "VPN")
        rv.setTextViewText(R.id.notif_text, if (paused) "Пауза" else text)
        rv.setOnClickPendingIntent(R.id.notif_stop, stopPendingIntent)
        // Кнопка пауза/возобновить
        rv.setTextViewText(R.id.notif_pause, if (paused) "Возобновить" else "Пауза")
        rv.setOnClickPendingIntent(R.id.notif_pause, if (paused) resumePendingIntent else pausePendingIntent)
        return rv
    }

    private val notificationBuilder by lazy {
        NotificationCompat.Builder(service, notificationChannel)
                .setShowWhen(false)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setSmallIcon(R.drawable.ic_stat_logo)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .setStyle(NotificationCompat.DecoratedCustomViewStyle())
                .setContentIntent(
                        PendingIntent.getActivity(
                                service,
                                0,
                                Intent(
                                        service,
                                        MainActivity::class.java
                                ).setFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT),
                                flags
                        )
                )
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
    }

    fun show(profileName: String, @StringRes contentTextId: Int) {
        paused = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // IMPORTANCE_DEFAULT → уведомление в ВЕРХНЕЙ части шторки (а не в
            // «Без звука», как при IMPORTANCE_LOW). Звук/вибрацию отключаем,
            // чтобы постоянное уведомление не пищало.
            val channel = NotificationChannel(
                notificationChannel, "VPN", NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                setSound(null, null)
                enableVibration(false)
                enableLights(false)
                setShowBadge(false)
            }
            Application.notification.createNotificationChannel(channel)
        }
        val title = profileName.takeIf { it.isNotBlank() } ?: "VPN"
        val text = service.getString(contentTextId)
        service.startForeground(
            notificationId, notificationBuilder
                .setCustomContentView(buildContentView(R.layout.notification_vpn, title, text))
                .setCustomBigContentView(buildContentView(R.layout.notification_vpn_big, title, text))
                .build()
        )
    }


    suspend fun start() {
        if (Settings.dynamicNotification && checkPermission()) {
//            commandClient.connect()
            startListenSystemInfo()
            withContext(Dispatchers.Main) {
                registerReceiver()
            }
        }
    }

    private fun registerReceiver() {
        // Защита от повторной регистрации: start() может вызываться снова при
        // возобновлении из паузы — без guard получили бы двойную регистрацию.
        if (receiverRegistered) return
        service.registerReceiver(this, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            addAction(Intent.ACTION_SCREEN_OFF)
        })
        receiverRegistered = true
    }

    fun updateStatus(previous:SystemInfo,status: SystemInfo) {
        val uplink=status.uplink_total - previous.uplink_total
        val downlink=status.downlink_total - previous.downlink_total
        val speed = "${Libbox.formatBytes(uplink)}/s ↑\t${Libbox.formatBytes(downlink)}/s ↓"
        val title = "${status.current_profile}"
        // url-test группу "lowest" показываем как «Авто».
        val outbound = status.current_outbound.replace("lowest", "Авто")
        // Свёрнутое: только скорость (одна строка, без обрезки).
        // Развёрнутое: скорость + текущий сервер.
        Application.notificationManager.notify(
                notificationId,
                notificationBuilder
                        .setCustomContentView(buildContentView(R.layout.notification_vpn, title, speed))
                        .setCustomBigContentView(
                                buildContentView(R.layout.notification_vpn_big, title, "$speed\n$outbound")
                        )
                        .build()
        )
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_SCREEN_ON -> {
                if (!paused) startListenSystemInfo()
            }

            Intent.ACTION_SCREEN_OFF -> {
                stopListenSystemInfo()
            }
        }
    }

    fun close() {
        stopListenSystemInfo()
        ServiceCompat.stopForeground(service, ServiceCompat.STOP_FOREGROUND_REMOVE)
        if (receiverRegistered) {
            service.unregisterReceiver(this)
            receiverRegistered = false
        }
    }

    private var streamingJob: Job? = null

    fun startListenSystemInfo() {
        // Cancel any previous stream if still running
        Log.d("notification","startListenSystemInfo")
        streamingJob?.cancel()

        streamingJob = streamingCoroutineScope.launch(Dispatchers.IO) {
            Log.d("notification", "startListenSystemInfo-launch")

            val coreClient = GrpcClientProvider.grpcClient.create(CoreClient::class)
            var retries = 0
            val maxRetries = 10

            while (isActive) {
                try {
                    var previous = coreClient.GetSystemInfo().executeBlocking(Empty())
                    retries = 0

                    while (isActive) {
                        delay(1_000)
                        val current = coreClient.GetSystemInfo().executeBlocking(Empty())
                        updateStatus(previous, current)
                        previous = current
                    }
                } catch (e: CancellationException) {
                    Log.d("notification", "SystemInfo polling cancelled")
                    if (!paused) notification.cancel(notificationId)
                    return@launch
                } catch (e: Exception) {
                    retries++
                    if (retries > maxRetries) {
                        Log.e("notification", "SystemInfo polling failed after $maxRetries retries", e)
                        if (!paused) notification.cancel(notificationId)
                        return@launch
                    }
                    Log.d("notification", "SystemInfo polling error, retry $retries/$maxRetries", e)
                    delay(2_000)
                }
            }
        }
    }
    fun stopListenSystemInfo(){
        try {
            streamingJob?.cancel()
        }catch (e: Exception){
            Log.d("notification", "Exception ${e}")
        }
    }
}