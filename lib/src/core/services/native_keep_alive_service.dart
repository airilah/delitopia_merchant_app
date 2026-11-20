import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NativeKeepAliveService {
  static final NativeKeepAliveService _instance = NativeKeepAliveService._internal();
  factory NativeKeepAliveService() => _instance;
  NativeKeepAliveService._internal();

  static const MethodChannel _channel = MethodChannel('com.delitopia.merchant/keep_alive');

  /// Start the native Android Foreground Service (with CPU WakeLock & Wi-Fi Lock)
  /// and enable Keep Screen On flag.
  Future<void> startForegroundWatchdog({String? statusText}) async {
    try {
      await _channel.invokeMethod('startForegroundWatchdog', {
        'statusText': ?statusText,
      });
      debugPrint('[NativeKeepAliveService] Foreground watchdog started & KeepScreenOn enabled');
    } catch (e) {
      debugPrint('[NativeKeepAliveService] Error starting foreground watchdog: $e');
    }
  }

  /// Enable or disable FLAG_KEEP_SCREEN_ON on the tablet window
  Future<void> setKeepScreenOn(bool enable) async {
    try {
      await _channel.invokeMethod('setKeepScreenOn', {'enable': enable});
    } catch (e) {
      debugPrint('[NativeKeepAliveService] Error setting keepScreenOn: $e');
    }
  }

  /// Check if the app is already whitelisted from Android battery optimizations
  Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      final result = await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return result ?? true;
    } catch (e) {
      debugPrint('[NativeKeepAliveService] Error checking battery optimizations: $e');
      return true;
    }
  }

  /// Open Android system prompt to ignore battery optimizations (Unrestricted background usage)
  Future<void> requestIgnoreBatteryOptimizations() async {
    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (e) {
      debugPrint('[NativeKeepAliveService] Error requesting ignore battery optimizations: $e');
    }
  }

  /// Physically wake up the tablet screen (for 15 seconds) when a new order arrives
  Future<void> wakeUpScreen() async {
    try {
      await _channel.invokeMethod('wakeUpScreen');
    } catch (e) {
      debugPrint('[NativeKeepAliveService] Error waking up screen: $e');
    }
  }

  /// Wake up the screen and bring Delitopia Outlet Activity to the front (over Grab/Shopee/Lockscreen)
  Future<void> bringAppToFront() async {
    try {
      await _channel.invokeMethod('bringAppToFront');
    } catch (e) {
      debugPrint('[NativeKeepAliveService] Error bringing app to front: $e');
    }
  }

  /// Force Android WebView to keep JavaScript timers running even when app is in background
  Future<void> resumeWebViewTimers() async {
    try {
      await _channel.invokeMethod('resumeWebViewTimers');
    } catch (e) {
      debugPrint('[NativeKeepAliveService] Error resuming WebView timers: $e');
    }
  }

  /// Display a high-priority Android Heads-Up Notification with FullScreenIntent
  Future<void> showOrderHeadsUpNotification({
    required String orderId,
    required String table,
    String? total,
  }) async {
    try {
      await _channel.invokeMethod('showOrderHeadsUpNotification', {
        'orderId': orderId,
        'table': table,
        'total': total ?? '',
      });
    } catch (e) {
      debugPrint('[NativeKeepAliveService] Error showing heads-up notification: $e');
    }
  }
}
