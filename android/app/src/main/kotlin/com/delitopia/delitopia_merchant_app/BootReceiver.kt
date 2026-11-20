package com.delitopia.delitopia_merchant_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action == Intent.ACTION_BOOT_COMPLETED ||
            action == "android.intent.action.QUICKBOOT_POWERON" ||
            action == "com.htc.intent.action.QUICKBOOT_POWERON"
        ) {
            Log.d("DelitopiaBootReceiver", "Device boot completed, starting MerchantForegroundService")
            try {
                val serviceIntent = Intent(context, MerchantForegroundService::class.java).apply {
                    this.action = MerchantForegroundService.ACTION_START
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(serviceIntent)
                } else {
                    context.startService(serviceIntent)
                }
            } catch (e: Exception) {
                Log.e("DelitopiaBootReceiver", "Failed to start service on boot: ${e.message}")
            }
        }
    }
}
