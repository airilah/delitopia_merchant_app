package com.delitopia.delitopia_merchant_app

import android.annotation.SuppressLint
import android.app.KeyguardManager
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.webkit.WebView
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

class MainActivity : FlutterActivity() {

    companion object {
        private const val TAG = "DelitopiaMainActivity"
        private const val CHANNEL_NAME = "com.delitopia.merchant/keep_alive"
        private var currentActivityRef: WeakReference<MainActivity>? = null
        private val mainHandler = Handler(Looper.getMainLooper())

        /**
         * Ensures Chromium WebView JS timers and network callbacks are never paused
         * when the cashier switches to GrabMerchant / ShopeePartner or locks the screen.
         */
        fun resumeWebViewTimersStatic() {
            mainHandler.post {
                try {
                    val activity = currentActivityRef?.get() ?: return@post
                    val webView = activity.findWebView(activity.window?.decorView)
                    if (webView != null) {
                        webView.resumeTimers()
                        webView.onResume()
                    }
                } catch (e: Exception) {
                    Log.w(TAG, "resumeWebViewTimersStatic error: ${e.message}")
                }
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        currentActivityRef = WeakReference(this)

        // 1. Keep Screen On continuously while app is open on cashier tablet
        enableKeepScreenOn(true)

        // 2. Allow waking and showing over lockscreen when order alarm fires
        configureLockscreenVisibility()

        // 3. Start Native Foreground Watchdog Service automatically
        startMerchantForegroundService(null)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startForegroundWatchdog" -> {
                        val statusText = call.argument<String>("statusText")
                        startMerchantForegroundService(statusText)
                        enableKeepScreenOn(true)
                        result.success(true)
                    }
                    "stopForegroundWatchdog" -> {
                        stopMerchantForegroundService()
                        result.success(true)
                    }
                    "setKeepScreenOn" -> {
                        val enable = call.argument<Boolean>("enable") ?: true
                        enableKeepScreenOn(enable)
                        result.success(true)
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        result.success(isIgnoringBatteryOptimizations())
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        requestIgnoreBatteryOptimizations()
                        result.success(true)
                    }
                    "wakeUpScreen" -> {
                        wakeUpTabletScreen()
                        result.success(true)
                    }
                    "bringAppToFront" -> {
                        wakeUpTabletScreen()
                        bringActivityToFront()
                        result.success(true)
                    }
                    "resumeWebViewTimers" -> {
                        resumeWebViewTimersStatic()
                        result.success(true)
                    }
                    "showOrderHeadsUpNotification" -> {
                        val orderId = call.argument<String>("orderId") ?: "Baru"
                        val table = call.argument<String>("table") ?: "Pesanan Masuk"
                        val total = call.argument<String>("total") ?: ""
                        showOrderHeadsUpNotification(orderId, table, total)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onResume() {
        super.onResume()
        currentActivityRef = WeakReference(this)
        enableKeepScreenOn(true)
        resumeWebViewTimersStatic()
    }

    override fun onPause() {
        super.onPause()
        // Counteract FlutterWebView pausing JS timers when switching to Grab/Shopee
        mainHandler.postDelayed({ resumeWebViewTimersStatic() }, 150L)
        mainHandler.postDelayed({ resumeWebViewTimersStatic() }, 600L)
        mainHandler.postDelayed({ resumeWebViewTimersStatic() }, 1500L)
    }

    override fun onStop() {
        super.onStop()
        // Keep WebView timers alive even when activity is stopped in background
        mainHandler.postDelayed({ resumeWebViewTimersStatic() }, 200L)
        mainHandler.postDelayed({ resumeWebViewTimersStatic() }, 1000L)
    }

    override fun onDestroy() {
        if (currentActivityRef?.get() === this) {
            currentActivityRef = null
        }
        super.onDestroy()
    }

    private fun enableKeepScreenOn(enable: Boolean) {
        runOnUiThread {
            try {
                if (enable) {
                    window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window?.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
            } catch (e: Exception) {
                Log.w(TAG, "enableKeepScreenOn error: ${e.message}")
            }
        }
    }

    private fun configureLockscreenVisibility() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setShowWhenLocked(true)
                setTurnScreenOn(true)
            } else {
                @Suppress("DEPRECATION")
                window?.addFlags(
                    WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                            WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                            WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "configureLockscreenVisibility error: ${e.message}")
        }
    }

    private fun startMerchantForegroundService(statusText: String?) {
        try {
            val intent = Intent(applicationContext, MerchantForegroundService::class.java).apply {
                action = MerchantForegroundService.ACTION_START
                if (!statusText.isNullOrBlank()) {
                    putExtra("status_text", statusText)
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                applicationContext.startForegroundService(intent)
            } else {
                applicationContext.startService(intent)
            }
        } catch (e: Exception) {
            Log.e(TAG, "startMerchantForegroundService error: ${e.message}")
        }
    }

    private fun stopMerchantForegroundService() {
        try {
            val intent = Intent(applicationContext, MerchantForegroundService::class.java).apply {
                action = MerchantForegroundService.ACTION_STOP
            }
            applicationContext.startService(intent)
        } catch (e: Exception) {
            Log.e(TAG, "stopMerchantForegroundService error: ${e.message}")
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
                pm?.isIgnoringBatteryOptimizations(packageName) ?: true
            } else {
                true
            }
        } catch (e: Exception) {
            true
        }
    }

    @SuppressLint("BatteryLife")
    private fun requestIgnoreBatteryOptimizations() {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !isIgnoringBatteryOptimizations()) {
                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:$packageName")
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                startActivity(intent)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Direct battery optimization dialog failed, opening settings: ${e.message}")
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    val fallback = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(fallback)
                }
            } catch (_: Exception) {}
        }
    }

    private fun wakeUpTabletScreen() {
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
            @Suppress("DEPRECATION")
            val screenWakeLock = pm.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                        PowerManager.ACQUIRE_CAUSES_WAKEUP or
                        PowerManager.ON_AFTER_RELEASE,
                "DelitopiaMerchant::OrderScreenWakeUpLock"
            )
            screenWakeLock.acquire(15_000L) // Keep screen bright for 15 seconds on incoming order
            Log.d(TAG, "Tablet screen woken up for incoming order")
        } catch (e: Exception) {
            Log.w(TAG, "wakeUpTabletScreen error: ${e.message}")
        }
    }

    private fun bringActivityToFront() {
        try {
            val intent = Intent(applicationContext, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                        Intent.FLAG_ACTIVITY_SINGLE_TOP or
                        Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            applicationContext.startActivity(intent)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val km = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
                km?.requestDismissKeyguard(this, null)
            }
        } catch (e: Exception) {
            Log.w(TAG, "bringActivityToFront error: ${e.message}")
        }
    }

    private fun showOrderHeadsUpNotification(orderId: String, table: String, total: String) {
        try {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
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
            val pendingIntent = PendingIntent.getActivity(this, 202, launchIntent, pendingFlags)

            val bodyText = if (total.isNotBlank()) {
                "Order #$orderId • $table • Total: $total"
            } else {
                "Order #$orderId • $table — Segera konfirmasi pesanan!"
            }

            val notification = NotificationCompat.Builder(this, MerchantForegroundService.CHANNEL_ID_ORDER_ALERT)
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle("🔔 Pesanan Baru Delitopia Masuk!")
                .setContentText(bodyText)
                .setStyle(NotificationCompat.BigTextStyle().bigText(bodyText))
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setAutoCancel(true)
                .setContentIntent(pendingIntent)
                .setFullScreenIntent(pendingIntent, true)
                .build()

            val notifId = MerchantForegroundService.NOTIFICATION_ID_ORDER_BASE + (orderId.hashCode() and 0x7FF)
            manager.notify(notifId, notification)
        } catch (e: Exception) {
            Log.w(TAG, "showOrderHeadsUpNotification error: ${e.message}")
        }
    }

    private fun findWebView(view: View?): WebView? {
        if (view == null) return null
        if (view is WebView) return view
        if (view is ViewGroup) {
            for (i in 0 until view.childCount) {
                val found = findWebView(view.getChildAt(i))
                if (found != null) return found
            }
        }
        return null
    }
}
