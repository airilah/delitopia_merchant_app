import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../core/constants/app_constants.dart';
import '../core/services/alarm_audio_service.dart';
import '../core/services/overlay_service.dart';
import 'widgets/error_connection_view.dart';

class MerchantWebViewScreen extends StatefulWidget {
  const MerchantWebViewScreen({super.key});

  @override
  State<MerchantWebViewScreen> createState() => _MerchantWebViewScreenState();
}

class _MerchantWebViewScreenState extends State<MerchantWebViewScreen> {
  late final WebViewController _controller;
  final AlarmAudioService _alarmAudioService = AlarmAudioService();
  final OverlayService _overlayService = OverlayService();
  int _loadingProgress = 0;
  bool _isLoading = true;
  bool _hasError = false;
  String? _errorMessage;
  DateTime? _lastBackPressTime;

  @override
  void initState() {
    super.initState();
    _alarmAudioService.init();
    _overlayService.initListener();
    _initWebView();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkOverlayPermission();
    });
  }

  Future<void> _checkOverlayPermission() async {
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
            'Agar pesanan Delitopia tetap muncul di atas aplikasi Grab Merchant & ShopeeFood, aktifkan izin "Tampilkan di atas aplikasi lain".',
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
          },
          onWebResourceError: (WebResourceError error) {
            // Main frame errors
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

  void _handleNativeBridgeMessage(JavaScriptMessage message) {
    debugPrint('[NativeBridge] Message received: ${message.message}');
    try {
      final data = jsonDecode(message.message) as Map<String, dynamic>;
      final action = data['action'] as String?;

      if (action == 'play_sound') {
        final soundType = (data['soundType'] ?? data['sound'] ?? '').toString().toLowerCase();
        final repeatCount = (data['repeatCount'] as num?)?.toInt() ?? 3;

        if (soundType == 'new_order' || soundType == 'orderbaru') {
          _alarmAudioService.playOrderAlarm(repeat: repeatCount);
          _overlayService.showOrderBubble(
            orderId: data['order_id']?.toString() ?? data['id']?.toString() ?? 'Baru',
            tableOrType: data['table']?.toString() ?? data['table_number']?.toString() ?? 'Pesanan Masuk',
            totalAmount: data['total']?.toString() ?? data['total_amount']?.toString(),
          );
        } else if (soundType == 'payment_success' || soundType == 'berhasilbayar') {
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
