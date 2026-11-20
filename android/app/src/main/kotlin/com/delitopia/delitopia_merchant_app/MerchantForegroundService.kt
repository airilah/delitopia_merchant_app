package com.delitopia.delitopia_merchant_app

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import androidx.core.app.NotificationCompat

class MerchantForegroundService : Service() {

    companion object {
        private const val TAG = "MerchantFGService"
        const val CHANNEL_ID_WATCHDOG = "delitopia_fg_watchdog_channel"
        const val CHANNEL_ID_ORDER_ALERT = "delitopia_order_heads_up_channel"
        const val NOTIFICATION_ID_WATCHDOG = 8801
        const val NOTIFICATION_ID_ORDER_BASE = 8900

        const val ACTION_START = "com.delitopia.delitopia_merchant_app.action.START_WATCHDOG"
        const val ACTION_STOP = "com.delitopia.delitopia_merchant_app.action.STOP_WATCHDOG"
        const val ACTION_UPDATE_STATUS = "com.delitopia.delitopia_merchant_app.action.UPDATE_STATUS"

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    private var cpuWakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private val watchdogHandler = Handler(Looper.getMainLooper())

    private val watchdogRunnable = object : Runnable {
        override fun run() {
            try {
                ensureLocksHeld()
                MainActivity.resumeWebViewTimersStatic()
            } catch (e: Exception) {
                Log.w(TAG, "Watchdog tick error: ${e.message}")
            } finally {
                if (isRunning) {
                    watchdogHandler.postDelayed(this, 10_000L)
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        Log.d(TAG, "onCreate: Initializing MerchantForegroundService")
        createNotificationChannels()
        acquireLocks()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_STOP) {
            Log.d(TAG, "Stopping MerchantForegroundService by explicit request")
            isRunning = false
            watchdogHandler.removeCallbacksAndMessages(null)
            releaseLocks()
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        val statusText = intent?.getStringExtra("status_text")
            ?: "Siaga 24 Jam: Alarm & Bubble pesanan aktif walau layar mati / buka Grab & Shopee"

        val notification = buildWatchdogNotification(statusText)

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID_WATCHDOG,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else {
                startForeground(NOTIFICATION_ID_WATCHDOG, notification)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error calling startForeground with type, falling back: ${e.message}")
            try {
                startForeground(NOTIFICATION_ID_WATCHDOG, notification)
            } catch (ex: Exception) {
                Log.e(TAG, "Fallback startForeground failed: ${ex.message}")
            }
        }

        isRunning = true
        ensureLocksHeld()

        watchdogHandler.removeCallbacks(watchdogRunnable)
        watchdogHandler.post(watchdogRunnable)

        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        Log.w(TAG, "onTaskRemoved detected: Scheduling automatic service restart in 2 seconds")
        try {
            val restartIntent = Intent(applicationContext, MerchantForegroundService::class.java).apply {
                action = ACTION_START
            }
            val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_ONE_SHOT
            }
            val pendingIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                PendingIntent.getForegroundService(applicationContext, 101, restartIntent, pendingFlags)
            } else {
                PendingIntent.getService(applicationContext, 101, restartIntent, pendingFlags)
            }

            val alarmManager = getSystemService(Context.ALARM_SERVICE) as? AlarmManager
            alarmManager?.setExactAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                SystemClock.elapsedRealtime() + 2000L,
                pendingIntent
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to schedule restart onTaskRemoved: ${e.message}")
        }
    }

    override fun onDestroy() {
        isRunning = false
        watchdogHandler.removeCallbacksAndMessages(null)
        releaseLocks()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun acquireLocks() {
        try {
            val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
            if (powerManager != null && cpuWakeLock == null) {
                cpuWakeLock = powerManager.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "DelitopiaMerchant::OrderWatchdogCpuWakeLock"
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
                Log.d(TAG, "CPU Partial WakeLock acquired")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to acquire CPU WakeLock: ${e.message}")
        }

        try {
            val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            if (wifiManager != null && wifiLock == null) {
                @Suppress("DEPRECATION")
                val lockMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wifiManager.createWifiLock(
                    lockMode,
                    "DelitopiaMerchant::OrderWatchdogWifiLock"
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
                Log.d(TAG, "Wi-Fi High Performance Lock acquired")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to acquire Wi-Fi Lock: ${e.message}")
        }
    }

    private fun ensureLocksHeld() {
        try {
            if (cpuWakeLock == null || cpuWakeLock?.isHeld != true) {
                acquireLocks()
            } else {
                // Ensure Wi-Fi lock is also held
                if (wifiLock?.isHeld != true) {
                    wifiLock?.acquire()
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "ensureLocksHeld warning: ${e.message}")
        }
    }

    private fun releaseLocks() {
        try {
            if (cpuWakeLock?.isHeld == true) {
                cpuWakeLock?.release()
            }
            cpuWakeLock = null
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing cpuWakeLock: ${e.message}")
        }

        try {
            if (wifiLock?.isHeld == true) {
                wifiLock?.release()
            }
            wifiLock = null
        } catch (e: Exception) {
            Log.w(TAG, "Error releasing wifiLock: ${e.message}")
        }
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return

            val watchdogChannel = NotificationChannel(
                CHANNEL_ID_WATCHDOG,
                "Status Siaga Kasir Delitopia",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Menjaga koneksi dan pemantauan pesanan Delitopia tetap aktif 24 jam di latar belakang"
                setShowBadge(false)
            }
            manager.createNotificationChannel(watchdogChannel)

            val orderAlertChannel = NotificationChannel(
                CHANNEL_ID_ORDER_ALERT,
                "Peringatan Pesanan Baru Delitopia",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Notifikasi prioritas tinggi saat pesanan baru masuk ke outlet"
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 500, 200, 500, 200, 700)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            manager.createNotificationChannel(orderAlertChannel)
        }
    }

    private fun buildWatchdogNotification(statusText: String): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val pendingIntent = PendingIntent.getActivity(this, 0, launchIntent, pendingFlags)

        return NotificationCompat.Builder(this, CHANNEL_ID_WATCHDOG)
            .setContentTitle("Delitopia Outlet — Mode Siaga Aktif")
            .setContentText(statusText)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setContentIntent(pendingIntent)
            .build()
    }
}
