package com.example.companion_app

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

/** Ongoing stream controls in the system notification shade (Controller + Shortcuts). */
object GBearStreamNotificationHelper {
    const val CHANNEL_ID = "gbear_stream_session_v2"
    private const val NOTIFICATION_ID = 28765

    const val ACTION_MAPPING = "com.gbear.companion.STREAM_MAPPING"
    const val ACTION_SHORTCUTS = "com.gbear.companion.STREAM_SHORTCUTS"
    const val ACTION_STOP = "com.gbear.companion.STREAM_STOP"
    const val ACTION_SWAP = "com.gbear.companion.STREAM_SWAP"

    fun show(context: Context, hostLabel: String) {
        refresh(context, hostLabel)
    }

    fun refresh(context: Context, hostLabel: String = GBearStreamSession.host) {
        showWithText(context, streamStatusText(hostLabel, viewerOpenHint = false))
    }

    private fun streamStatusText(hostLabel: String, viewerOpenHint: Boolean): String {
        val base = if (hostLabel.isNotEmpty()) "Streaming from $hostLabel" else "Streaming Mac desktop"
        return buildString {
            append(base)
            if (GBearStreamSession.swapMouseModeActive) {
                append(" — Swap: stick = cursor, A/B/X = click & drag")
            }
            if (viewerOpenHint) append(" — tap a button below")
        }
    }

    private fun showWithText(context: Context, contentText: String) {
        val appContext = context.applicationContext
        createChannel(appContext)
        if (!canPostNotifications(appContext)) return

        val mappingIntent = actionIntent(appContext, ACTION_MAPPING)
        val shortcutsIntent = actionIntent(appContext, ACTION_SHORTCUTS)
        val stopIntent = actionIntent(appContext, ACTION_STOP)
        val swapIntent = actionIntent(appContext, ACTION_SWAP)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0

        val mappingPending = PendingIntent.getBroadcast(appContext, 2, mappingIntent, flags)
        val shortcutsPending = PendingIntent.getBroadcast(appContext, 4, shortcutsIntent, flags)
        val stopPending = PendingIntent.getBroadcast(appContext, 5, stopIntent, flags)
        val swapPending = PendingIntent.getBroadcast(appContext, 6, swapIntent, flags)

        val launchIntent = Intent(appContext, MainActivity::class.java).apply {
            this.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val contentPending = PendingIntent.getActivity(appContext, 3, launchIntent, flags)

        val remote = RemoteViews(appContext.packageName, R.layout.gbear_stream_notification)
        remote.setTextViewText(R.id.stream_text, contentText)
        val swapLabel = if (GBearStreamSession.swapMouseModeActive) {
            appContext.getString(R.string.gbear_stream_action_swap_on)
        } else {
            appContext.getString(R.string.gbear_stream_action_swap)
        }
        remote.setTextViewText(R.id.btn_swap, swapLabel)
        remote.setOnClickPendingIntent(R.id.btn_stop, stopPending)
        remote.setOnClickPendingIntent(R.id.btn_swap, swapPending)
        remote.setOnClickPendingIntent(R.id.btn_controller, mappingPending)
        remote.setOnClickPendingIntent(R.id.btn_shortcuts, shortcutsPending)

        // Do not use DecoratedCustomViewStyle — Samsung/One UI collapses to title-only and hides buttons.
        val notification = NotificationCompat.Builder(appContext, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(contentPending)
            .setCustomContentView(remote)
            .setCustomBigContentView(remote)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setShowWhen(false)
            .setUsesChronometer(false)
            .addAction(android.R.drawable.ic_media_pause, "Stop", stopPending)
            .addAction(
                android.R.drawable.ic_menu_rotate,
                swapLabel,
                swapPending,
            )
            .addAction(android.R.drawable.ic_menu_manage, "Controller", mappingPending)
            .addAction(android.R.drawable.ic_menu_edit, "Shortcuts", shortcutsPending)
            .build()

        NotificationManagerCompat.from(appContext).notify(NOTIFICATION_ID, notification)
    }

    private fun actionIntent(context: Context, action: String): Intent =
        Intent(context, GBearStreamNotificationReceiver::class.java).apply {
            this.action = action
        }

    fun dismiss(context: Context) {
        NotificationManagerCompat.from(context.applicationContext).cancel(NOTIFICATION_ID)
    }

    fun updateViewerHint(context: Context, hostLabel: String, viewerOpen: Boolean) {
        if (!GBearStreamSession.hostStreamActive) {
            dismiss(context)
            return
        }
        showWithText(
            context.applicationContext,
            streamStatusText(hostLabel, viewerOpenHint = !viewerOpen),
        )
    }

    private fun createChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.deleteNotificationChannel("gbear_stream_session")
        manager.deleteNotificationChannel("playnite_stream_session")
        manager.deleteNotificationChannel("playnite_stream_session_v2")
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "GBear stream",
            NotificationManager.IMPORTANCE_HIGH,
        ).apply {
            description = "Controls while streaming your Mac desktop"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun canPostNotifications(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }
}
