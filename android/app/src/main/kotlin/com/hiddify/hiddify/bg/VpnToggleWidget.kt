package com.hiddify.hiddify.bg

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.widget.RemoteViews
import com.hiddify.hiddify.R
import com.hiddify.hiddify.Settings
import com.hiddify.hiddify.ShortcutActivity

/**
 * Домашний виджет 1x1: тап включает/выключает VPN.
 *
 * Сам тоггл переиспользует [ShortcutActivity] (та же логика, что у launcher-ярлыка
 * «quick_toggle»): она биндится к сервису, по текущему статусу делает start/stop и
 * сразу закрывается. Это надёжнее, чем биндиться к сервису прямо в BroadcastReceiver.
 *
 * Иконка вкл/выкл берётся из кэша [Settings.vpnRunning], который обновляет
 * ServiceBinder при каждой смене статуса (он же дёргает [refresh]).
 */
class VpnToggleWidget : AppWidgetProvider() {

    companion object {
        fun refresh(context: Context) {
            val mgr = AppWidgetManager.getInstance(context) ?: return
            val ids = mgr.getAppWidgetIds(ComponentName(context, VpnToggleWidget::class.java))
            for (id in ids) updateAppWidget(context, mgr, id)
        }

        private fun updateAppWidget(context: Context, mgr: AppWidgetManager, appWidgetId: Int) {
            val running = Settings.vpnRunning
            val views = RemoteViews(context.packageName, R.layout.widget_vpn_toggle)
            views.setInt(
                R.id.widget_root,
                "setBackgroundResource",
                if (running) R.drawable.widget_bg_on else R.drawable.widget_bg_off,
            )
            views.setContentDescription(R.id.widget_root, context.getString(R.string.quick_toggle))

            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
            val toggleIntent = Intent(context, ShortcutActivity::class.java)
                .setAction(Intent.ACTION_MAIN)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val pi = PendingIntent.getActivity(context, 0, toggleIntent, flags)
            views.setOnClickPendingIntent(R.id.widget_root, pi)

            mgr.updateAppWidget(appWidgetId, views)
        }
    }

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (id in appWidgetIds) updateAppWidget(context, appWidgetManager, id)
    }
}
