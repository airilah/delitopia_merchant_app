import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_overlay_window/flutter_overlay_window.dart';
import 'alarm_audio_service.dart';
import 'native_keep_alive_service.dart';

class OverlayService {
  static final OverlayService _instance = OverlayService._internal();
  factory OverlayService() => _instance;
  OverlayService._internal();

  bool _isListening = false;
  void Function(String? orderId)? onOpenOrdersRequested;

  void initListener({void Function(String? orderId)? onOpenOrders}) {
    if (onOpenOrders != null) {
      onOpenOrdersRequested = onOpenOrders;
    }
    if (_isListening) return;
    _isListening = true;

    FlutterOverlayWindow.overlayListener.listen((dynamic rawData) {
      debugPrint('[OverlayService] Message from overlay: $rawData');
      if (rawData == null) return;

      try {
        final Map<String, dynamic> data =
            rawData is Map ? Map<String, dynamic>.from(rawData) : jsonDecode(rawData.toString());

        final action = data['action'] as String?;
        if (action == 'stop_sound') {
          AlarmAudioService().stop();
        } else if (action == 'close_overlay') {
          closeOverlay();
        } else if (action == 'open_app') {
          AlarmAudioService().stop();
          closeOverlay();
          NativeKeepAliveService().bringAppToFront();
          onOpenOrdersRequested?.call(data['order_id']?.toString());
        }
      } catch (e) {
        debugPrint('[OverlayService] Error parsing overlay message: $e');
      }
    });
  }

  /// Check if SYSTEM_ALERT_WINDOW permission is granted
  Future<bool> isPermissionGranted() async {
    return await FlutterOverlayWindow.isPermissionGranted();
  }

  /// Request SYSTEM_ALERT_WINDOW permission (opens Android system setting)
  Future<bool?> requestPermission() async {
    return await FlutterOverlayWindow.requestPermission();
  }

  /// Check if floating overlay is currently displayed
  Future<bool> isActive() async {
    return await FlutterOverlayWindow.isActive();
  }

  /// Display or update the floating order bubble over all other apps (Grab / Shopee)
  Future<void> showOrderBubble({
    required String orderId,
    String? tableOrType,
    String? totalAmount,
  }) async {
    initListener();

    final hasPermission = await isPermissionGranted();
    if (!hasPermission) {
      debugPrint('[OverlayService] Cannot show overlay: permission not granted');
      return;
    }

    final active = await FlutterOverlayWindow.isActive();
    if (!active) {
      await FlutterOverlayWindow.showOverlay(
        enableDrag: true,
        overlayTitle: 'Pesanan Baru Delitopia',
        overlayContent: 'Ada pesanan baru masuk di Delitopia',
        flag: OverlayFlag.defaultFlag,
        visibility: NotificationVisibility.visibilityPublic,
        positionGravity: PositionGravity.auto,
        height: 220,
        width: 220,
        startPosition: const OverlayPosition(0, -200),
        dismissConfig: const OverlayDismissConfig(
          shape: OverlayDismissShape.circle,
          borderRadius: 20,
          backgroundColor: Color(0xCC333333),
          activeBackgroundColor: Color(0xFFD32F2F),
          borderWidth: 2,
          borderColor: Colors.white30,
          activeBorderColor: Colors.white,
        ),
      );
    }

    // Share order data to the running overlay isolate
    final payload = {
      'order_id': orderId,
      'table': tableOrType ?? 'Pesanan Masuk',
      'total': totalAmount ?? '',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    // Small delay to ensure overlay isolate listener is mounted if newly created
    Future.delayed(const Duration(milliseconds: 300), () {
      FlutterOverlayWindow.shareData(jsonEncode(payload));
    });
  }

  /// Close the floating overlay
  Future<void> closeOverlay() async {
    if (await FlutterOverlayWindow.isActive()) {
      await FlutterOverlayWindow.closeOverlay();
    }
  }
}
