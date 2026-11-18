import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import '../core/constants/app_constants.dart';
import 'widgets/error_connection_view.dart';

class MerchantWebViewScreen extends StatefulWidget {
  const MerchantWebViewScreen({super.key});

  @override
  State<MerchantWebViewScreen> createState() => _MerchantWebViewScreenState();
}

class _MerchantWebViewScreenState extends State<MerchantWebViewScreen> {
  late final WebViewController _controller;
  int _loadingProgress = 0;
  bool _isLoading = true;
  bool _hasError = false;
  String? _errorMessage;
  DateTime? _lastBackPressTime;

  @override
  void initState() {
    super.initState();
    _initWebView();
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
    }

    _controller = controller;
  }

  void _handleNativeBridgeMessage(JavaScriptMessage message) {
    debugPrint('[NativeBridge] Message received: ${message.message}');
    // In Phase 2, this will be wired to trigger native audio and bubble directly
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
