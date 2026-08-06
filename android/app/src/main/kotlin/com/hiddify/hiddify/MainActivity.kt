package com.hiddify.hiddify

import android.annotation.SuppressLint
import android.content.Intent
import android.Manifest
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.util.Log
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.lifecycleScope
import com.hiddify.hiddify.bg.ServiceConnection
import com.hiddify.hiddify.bg.ServiceNotification
import com.hiddify.hiddify.constant.Alert
import com.hiddify.hiddify.constant.ServiceMode
import com.hiddify.hiddify.constant.Status
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.LinkedList


class MainActivity : FlutterFragmentActivity(), ServiceConnection.Callback {
    companion object {
        private const val TAG = "ANDROID/MyActivity"
        lateinit var instance: MainActivity

        const val VPN_PERMISSION_REQUEST_CODE = 1001
        const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1010
    }

    private val connection = ServiceConnection(this, this)

    val logList = LinkedList<String>()
    var logCallback: ((Boolean) -> Unit)? = null
    val serviceStatus = MutableLiveData(Status.Stopped)
    val serviceAlerts = MutableLiveData<ServiceEvent?>(null)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        instance = this
        reconnect()
        flutterEngine.plugins.add(MethodHandler(lifecycleScope))
        flutterEngine.plugins.add(PlatformSettingsHandler())
        flutterEngine.plugins.add(EventHandler())
        flutterEngine.plugins.add(LogHandler())

        // Канал для устойчивого идентификатора устройства (анти-абуз пробного периода).
        // Settings.Secure.ANDROID_ID переживает переустановку приложения и привязан
        // к ключу подписи + пакету, поэтому стабилен именно для нашего APK.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.ihgap.vpn/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAndroidId" -> {
                        val id = android.provider.Settings.Secure.getString(
                            contentResolver,
                            android.provider.Settings.Secure.ANDROID_ID,
                        )
                        result.success(id)
                    }
                    // Включён ли экран устройства. Нужно failover'у (Dart):
                    // активная HTTP-проба связи разрешена при включённом экране,
                    // даже если наше приложение в фоне — радиомодуль в это время
                    // и так активен, а детект белых списков остаётся быстрым.
                    "isScreenOn" -> {
                        result.success(Application.powerManager.isInteractive)
                    }
                    // Прошёл ли VPN-туннель системную проверку связности.
                    // Система шлёт свою пробу ПО VPN-СЕТИ, то есть пакет идёт
                    // через TUN и через проверяемый стек — и только потом ядро
                    // решает по правилам, отправить его на сервер или напрямую.
                    // Поэтому флаг отвечает ровно на наш вопрос «стек работает?»
                    // и не зависит ни от geoip-правил, ни от «только зарубежного
                    // трафика». Проба самого приложения так не умеет: своё
                    // приложение исключено из туннеля (VPNService.openTun).
                    "isVpnValidated" -> {
                        val cm = getSystemService(ConnectivityManager::class.java)
                        var validated = false
                        if (cm != null) {
                            for (network in cm.allNetworks) {
                                val caps = cm.getNetworkCapabilities(network) ?: continue
                                if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
                                if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) {
                                    validated = true
                                    break
                                }
                            }
                        }
                        result.success(validated)
                    }
                    // Откуда установлено приложение: "com.android.vending" = Google Play.
                    // По этому признаку бэкенд решает, показывать ли кнопки внешней
                    // оплаты (Payments policy запрещает их только для установок из Play).
                    "getInstallerPackage" -> {
                        val installer = try {
                            if (android.os.Build.VERSION.SDK_INT >= 30) {
                                packageManager.getInstallSourceInfo(packageName).installingPackageName
                            } else {
                                @Suppress("DEPRECATION")
                                packageManager.getInstallerPackageName(packageName)
                            }
                        } catch (_: Exception) {
                            null
                        }
                        result.success(installer ?: "")
                    }
                    else -> result.notImplemented()
                }
            }
//        flutterEngine.plugins.add(GroupsChannel(lifecycleScope))
//        flutterEngine.plugins.add(ActiveGroupsChannel(lifecycleScope))
//        flutterEngine.plugins.add(StatsChannel(lifecycleScope))
    }

    fun reconnect() {
        connection.reconnect()
    }

    @SuppressLint("NewApi")
    fun startService() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !ServiceNotification.checkPermission()) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }
        startService0()
    }

    private fun startService0() {
        lifecycleScope.launch(Dispatchers.IO) {
            if (Settings.rebuildServiceMode()) {
                connection.reconnect()
            }
            if (Settings.serviceMode == ServiceMode.VPN) {
                if (prepare()) {
                    return@launch
                }
            }
            val intent = Intent(Application.application, Settings.serviceClass())
            withContext(Dispatchers.Main) {
                ContextCompat.startForegroundService(this@MainActivity, intent)
            }
            Settings.startedByUser = true
        }
    }

    private suspend fun prepare() = withContext(Dispatchers.Main) {
        try {
            val intent = VpnService.prepare(this@MainActivity)
            if (intent != null) {
                prepareLauncher.launch(intent)
                true
            } else {
                false
            }
        } catch (e: Exception) {
            onServiceAlert(Alert.RequestVPNPermission, e.message)
            true
        }
    }
    private val notificationPermissionLauncher =
        registerForActivityResult(
            ActivityResultContracts.RequestPermission(),
        ) { isGranted ->
            if (Settings.dynamicNotification && !isGranted) {
                onServiceAlert(Alert.RequestNotificationPermission, null)
            } else {
                startService0()
            }
        }

    private val prepareLauncher =
        registerForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            if (result.resultCode == RESULT_OK) {
                startService0()
            } else {
                onServiceAlert(Alert.RequestVPNPermission, null)
            }
        }

    override fun onServiceStatusChanged(status: Status) {
        serviceStatus.postValue(status)
    }

    override fun onServiceAlert(type: Alert, message: String?) {
        serviceAlerts.postValue(ServiceEvent(Status.Stopped, type, message))
    }




    override fun onDestroy() {
        connection.disconnect()
        super.onDestroy()
    }

    @SuppressLint("NewApi")
    private fun grantNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST_CODE
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (requestCode == NOTIFICATION_PERMISSION_REQUEST_CODE) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                startService()
            } else onServiceAlert(Alert.RequestNotificationPermission, null)
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_PERMISSION_REQUEST_CODE) {
            if (resultCode == RESULT_OK) startService()
            else onServiceAlert(Alert.RequestVPNPermission, null)
        } else if (requestCode == NOTIFICATION_PERMISSION_REQUEST_CODE) {
            if (resultCode == RESULT_OK) startService()
            else onServiceAlert(Alert.RequestNotificationPermission, null)
        }
    }
}
