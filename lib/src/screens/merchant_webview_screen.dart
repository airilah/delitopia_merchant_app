import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../core/constants/app_constants.dart';
import '../core/services/alarm_audio_service.dart';
import '../core/services/native_keep_alive_service.dart';
import '../core/services/overlay_service.dart';
import 'widgets/error_connection_view.dart';

class MerchantWebViewScreen extends StatefulWidget {
  const MerchantWebViewScreen({super.key});

  @override
  State<MerchantWebViewScreen> createState() => _MerchantWebViewScreenState();
}

class _MerchantWebViewScreenState extends State<MerchantWebViewScreen>
    with WidgetsBindingObserver {
  late final WebViewController _controller;
  final AlarmAudioService _alarmAudioService = AlarmAudioService();
  final OverlayService _overlayService = OverlayService();
  final NativeKeepAliveService _keepAliveService = NativeKeepAliveService();

  Timer? _watchdogTimer;
  final Map<String, int> _recentAlertTimestamps = {};

  int _loadingProgress = 0;
  bool _isLoading = true;
  bool _hasError = false;
  String? _errorMessage;
  DateTime? _lastBackPressTime;

  /// Self-contained JavaScript background order poller injected by the native watchdog
  /// every 10 seconds. Ensures that even when the tablet screen is locked or Grab/Shopee
  /// is in the foreground, incoming orders are detected immediately using the WebView's cookies.
  static const String _backgroundOrderPollJs = r'''
(function() {
  try {
    if (typeof window.__delitopiaForceNotificationCheck === 'function') {
      window.__delitopiaForceNotificationCheck();
    }
    if (window.__delitopiaNativePollingInFlight) return;
    window.__delitopiaNativePollingInFlight = true;

    fetch('/api/notification/my-notifications', {
      method: 'GET',
      headers: {
        'Accept': 'application/json',
        'Cache-Control': 'no-cache'
      },
      cache: 'no-store',
      credentials: 'include'
    })
    .then(function(res) {
      if (!res.ok) return null;
      return res.json();
    })
    .then(function(json) {
      if (!json) return;
      var list = Array.isArray(json.data)
        ? json.data
        : (json.data && Array.isArray(json.data.data) ? json.data.data : []);
      if (!Array.isArray(list)) return;

      if (!window.__delitopiaWatchdogSeenIds) {
        window.__delitopiaWatchdogSeenIds = {};
        for (var i = 0; i < list.length; i++) {
          if (list[i] && list[i].id) {
            window.__delitopiaWatchdogSeenIds[String(list[i].id)] = true;
          }
        }
        return;
      }

      var newItems = [];
      for (var j = 0; j < list.length; j++) {
        var item = list[j];
        if (item && item.id && !item.is_read && !window.__delitopiaWatchdogSeenIds[String(item.id)]) {
          window.__delitopiaWatchdogSeenIds[String(item.id)] = true;
          newItems.push(item);
        } else if (item && item.id) {
          window.__delitopiaWatchdogSeenIds[String(item.id)] = true;
        }
      }

      if (newItems.length > 0 && window.DelitopiaNativeBridge) {
        var newOrder = null;
        var paymentSuccess = null;

        for (var k = 0; k < newItems.length; k++) {
          var n = newItems[k];
          var sType = String(n.sound_type || '').toLowerCase();
          var tKey = String(n.template_key || '').toLowerCase();
          var cat = String(n.category || '').toLowerCase();
          var title = String(n.title || '').toLowerCase();
          var body = String(n.body || '').toLowerCase();

          if (
            sType === 'new_order' ||
            sType === 'orderbaru' ||
            tKey === 'order_new_admin' ||
            (cat === 'order' && (title.indexOf('pesanan baru') !== -1 || body.indexOf('pesanan baru') !== -1))
          ) {
            newOrder = n;
            break;
          }
          if (
            sType === 'payment_success' ||
            sType === 'berhasilbayar' ||
            tKey === 'order_paid_admin' ||
            title.indexOf('pembayaran lunas') !== -1
          ) {
            paymentSuccess = n;
          }
        }

        if (newOrder) {
          var meta = {};
          try {
            meta = typeof newOrder.metadata === 'string'
              ? JSON.parse(newOrder.metadata)
              : (newOrder.metadata || {});
          } catch (e) {}

          window.DelitopiaNativeBridge.postMessage(JSON.stringify({
            action: 'play_sound',
            soundType: 'new_order',
            repeatCount: 3,
            notif_id: String(newOrder.id),
            order_id: String(newOrder.order_id || (meta && meta.order_id) || newOrder.id),
            table: String((meta && (meta.table_number || meta.table)) || 'Take Away / Meja'),
            total: String((meta && (meta.total_amount || meta.total)) || '')
          }));
        } else if (paymentSuccess) {
          window.DelitopiaNativeBridge.postMessage(JSON.stringify({
            action: 'play_sound',
            soundType: 'payment_success',
            repeatCount: 1,
            notif_id: String(paymentSuccess.id)
          }));
        }
      }
    })
    .catch(function() {})
    .finally(function() {
      window.__delitopiaNativePollingInFlight = false;
    });
  } catch (err) {
    window.__delitopiaNativePollingInFlight = false;
  }
})();
''';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _alarmAudioService.init();

    // Start Native Foreground Service (WakeLock + WifiLock + KeepScreenOn)
    _keepAliveService.startForegroundWatchdog();
    _keepAliveService.setKeepScreenOn(true);

    // Initialize Overlay listener & handle "Buka Kasir" button tap from floating bubble
    _overlayService.initListener(
      onOpenOrders: (String? orderId) {
        _navigateToOrdersPage();
      },
    );

    _initWebView();
    _startWatchdogTimer();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPermissionsAndBatteryOptimization();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    debugPrint('[MerchantWebViewScreen] Lifecycle changed: $state');

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      // Ensure Foreground Service & WebView timers remain active when switching to Grab/Shopee or locking screen
      _keepAliveService.startForegroundWatchdog();
      _keepAliveService.resumeWebViewTimers();
    } else if (state == AppLifecycleState.resumed) {
      _keepAliveService.setKeepScreenOn(true);
      _keepAliveService.resumeWebViewTimers();
      _triggerImmediatePoll();
    }
  }

  void _startWatchdogTimer() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _keepAliveService.resumeWebViewTimers();
      _triggerImmediatePoll();
    });
  }

  void _triggerImmediatePoll() {
    if (_hasError) return;
    try {
      _controller.runJavaScript(_backgroundOrderPollJs);
    } catch (e) {
      debugPrint('[Watchdog] JS poll tick skipped: $e');
    }
  }

  void _navigateToOrdersPage() {
    try {
      _controller.runJavaScript('''
        if (window.location.pathname !== '/orders') {
          window.location.href = '/orders';
        } else if (typeof window.__delitopiaForceNotificationCheck === 'function') {
          window.__delitopiaForceNotificationCheck();
        }
      ''');
    } catch (e) {
      debugPrint('[MerchantWebViewScreen] Error navigating to orders: $e');
    }
  }

  Future<void> _checkPermissionsAndBatteryOptimization() async {
    // 1. Request Notification permission on Android 13+ so Foreground Service & Heads-Up alerts show
    try {
      final notifStatus = await Permission.notification.status;
      if (notifStatus.isDenied) {
        await Permission.notification.request();
      }
    } catch (e) {
      debugPrint('[Permissions] Notification permission request error: $e');
    }

    // 2. Request Battery Optimization Exemption (Unrestricted background usage)
    try {
      final ignoringBattery = await _keepAliveService.isIgnoringBatteryOptimizations();
      if (!ignoringBattery) {
        await _keepAliveService.requestIgnoreBatteryOptimizations();
      }
    } catch (e) {
      debugPrint('[Permissions] Battery optimization check error: $e');
    }

    // 3. Check Overlay Permission (SYSTEM_ALERT_WINDOW) for Floating Order Bubble over Grab/Shopee
    final granted = await _overlayService.isPermissionGranted();
    if (!granted && mounted) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.layers_rounded, color: Color(AppConstants.primaryColorHex)),
              SizedBox(width: 8),
              Expanded(
                child: Text('Izin Tampilan Melayang', style: TextStyle(fontSize: 16)),
              ),
            ],
          ),
          content: const Text(
            'Agar pesanan Delitopia tetap muncul di atas aplikasi Grab Merchant & ShopeeFood serta saat layar terkunci, aktifkan izin "Tampilkan di atas aplikasi lain".',
            style: TextStyle(fontSize: 13),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Nanti Saja'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                _overlayService.requestPermission();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(AppConstants.primaryColorHex),
                foregroundColor: Colors.white,
              ),
              child: const Text('Aktifkan'),
            ),
          ],
        ),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _watchdogTimer?.cancel();
    _alarmAudioService.dispose();
    super.dispose();
  }

  void _initWebView() {
    final PlatformWebViewControllerCreationParams params =
        const PlatformWebViewControllerCreationParams();

    final WebViewController controller =
        WebViewController.fromPlatformCreationParams(params);

    controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            if (mounted) {
              setState(() {
                _loadingProgress = progress;
                _isLoading = progress < 100;
              });
            }
          },
          onPageStarted: (String url) {
            if (mounted) {
              setState(() {
                _isLoading = true;
                _hasError = false;
                _errorMessage = null;
              });
            }
          },
          onPageFinished: (String url) {
            if (mounted) {
              setState(() {
                _isLoading = false;
              });
            }
            _keepAliveService.resumeWebViewTimers();
            _triggerImmediatePoll();
          },
          onWebResourceError: (WebResourceError error) {
            if (error.isForMainFrame ?? true) {
              if (mounted) {
                setState(() {
                  _hasError = true;
                  _errorMessage = error.description;
                });
              }
            }
          },
          onNavigationRequest: (NavigationRequest request) {
            return NavigationDecision.navigate;
          },
        ),
      )
      ..addJavaScriptChannel(
        AppConstants.nativeBridgeChannel,
        onMessageReceived: _handleNativeBridgeMessage,
      )
      ..loadRequest(Uri.parse(AppConstants.adminHubUrl));

    // Android specific configurations
    if (controller.platform is AndroidWebViewController) {
      final androidController = controller.platform as AndroidWebViewController;
      AndroidWebViewController.enableDebugging(false);
      androidController.setMediaPlaybackRequiresUserGesture(false);

      // Handle HTML5 Camera & Microphone permission requests (for QR / Barcode Scanner)
      androidController.setOnPlatformPermissionRequest((request) async {
        debugPrint('[WebView] onPermissionRequest: ${request.types}');
        try {
          if (request.types.contains(WebViewPermissionResourceType.camera)) {
            final status = await Permission.camera.request();
            if (status.isGranted) {
              await request.grant();
            } else {
              await request.deny();
            }
          } else if (request.types.contains(WebViewPermissionResourceType.microphone)) {
            final status = await Permission.microphone.request();
            if (status.isGranted) {
              await request.grant();
            } else {
              await request.deny();
            }
          } else {
            await request.grant();
          }
        } catch (e) {
          debugPrint('[WebView] Error requesting platform permission: $e');
          await request.grant();
        }
      });
    }

    _controller = controller;
  }

  /// Deduplicate alerts within 15 seconds so dual-detection (React + Native Watchdog)
  /// never plays the alarm twice for the exact same order/notification event.
  bool _isDuplicateAlert(String key) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _recentAlertTimestamps.removeWhere((_, ts) => now - ts > 15000);
    final lastTs = _recentAlertTimestamps[key];
    if (lastTs != null && now - lastTs < 15000) {
      return true;
    }
    _recentAlertTimestamps[key] = now;
    return false;
  }

  void _handleNativeBridgeMessage(JavaScriptMessage message) {
    debugPrint('[NativeBridge] Message received: ${message.message}');
    try {
      final data = jsonDecode(message.message) as Map<String, dynamic>;
      final action = data['action'] as String?;

      if (action == 'play_sound') {
        final soundType = (data['soundType'] ?? data['sound'] ?? '').toString().toLowerCase();
        final repeatCount = (data['repeatCount'] as num?)?.toInt() ?? 3;
        final orderId = data['order_id']?.toString() ?? data['id']?.toString() ?? 'Baru';
        final notifId = data['notif_id']?.toString() ?? orderId;
        final tableOrType = data['table']?.toString() ?? data['table_number']?.toString() ?? 'Pesanan Masuk';
        final totalAmount = data['total']?.toString() ?? data['total_amount']?.toString();

        if (soundType == 'new_order' || soundType == 'orderbaru') {
          final dedupKey = 'new_order_${orderId}_$notifId';
          if (orderId != 'Baru' && _isDuplicateAlert(dedupKey)) {
            debugPrint('[NativeBridge] Skipping duplicate new_order alert for $dedupKey');
            return;
          }

          // 1. Physically wake up tablet screen if it was turned off or dimmed
          _keepAliveService.wakeUpScreen();

          // 2. Display high-priority Android Heads-Up Notification (visible over lockscreen & apps)
          _keepAliveService.showOrderHeadsUpNotification(
            orderId: orderId,
            table: tableOrType,
            total: totalAmount,
          );

          // 3. Play STREAM_ALARM audio (orderbaru.mp3) at maximum volume
          _alarmAudioService.playOrderAlarm(repeat: repeatCount);

          // 4. Show Floating Order Bubble over GrabMerchant / ShopeeFood
          _overlayService.showOrderBubble(
            orderId: orderId,
            tableOrType: tableOrType,
            totalAmount: totalAmount,
          );
        } else if (soundType == 'payment_success' || soundType == 'berhasilbayar') {
          final dedupKey = 'pay_success_$notifId';
          if (notifId != 'Baru' && _isDuplicateAlert(dedupKey)) {
            return;
          }
          _alarmAudioService.playPaymentSuccess();
        }
      } else if (action == 'stop_sound') {
        _alarmAudioService.stop();
      } else if (action == 'close_overlay') {
        _overlayService.closeOverlay();
      }
    } catch (e) {
      debugPrint('[NativeBridge] Error parsing bridge message: $e');
    }
  }

  Future<void> _handleRefresh() async {
    setState(() {
      _hasError = false;
      _errorMessage = null;
    });
    await _controller.reload();
  }

  Future<bool> _handlePopScope() async {
    if (await _controller.canGoBack()) {
      await _controller.goBack();
      return false;
    }

    final now = DateTime.now();
    if (_lastBackPressTime == null ||
        now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
      _lastBackPressTime = now;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Tekan sekali lagi untuk keluar dari aplikasi outlet'),
            duration: Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return false;
    }

    return true;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await _handlePopScope();
        if (shouldPop) {
          SystemNavigator.pop();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.white,
        body: SafeArea(
          child: Stack(
            children: [
              if (!_hasError)
                RefreshIndicator(
                  onRefresh: _handleRefresh,
                  color: const Color(AppConstants.primaryColorHex),
                  child: WebViewWidget(controller: _controller),
                ),
              if (_hasError)
                ErrorConnectionView(
                  onRetry: _handleRefresh,
                  errorMessage: _errorMessage,
                ),
              if (_isLoading && !_hasError)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(
                    value: _loadingProgress / 100.0,
                    backgroundColor: Colors.grey.shade200,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(AppConstants.primaryColorHex),
                    ),
                    minHeight: 3,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
