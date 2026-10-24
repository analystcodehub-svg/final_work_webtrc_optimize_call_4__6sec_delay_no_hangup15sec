import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionHelper {
  static bool _isSheetOpen = false;
  static DateTime? _lastDismissedTime;

  static Future<void> checkAndRequestNotificationPermission(BuildContext context) async {
    final status = await Permission.notification.status;
    if (!status.isGranted && context.mounted) {
      await showNotificationBottomSheet(context);
    }
  }

  static Future<bool> showNotificationBottomSheet(
    BuildContext context, {
    VoidCallback? onGranted,
    bool force = false,
  }) async {
    final status = await Permission.notification.status;
    if (status.isGranted) {
      onGranted?.call();
      return true;
    }

    if (_isSheetOpen || !context.mounted) return false;

    // Small debounce (2 seconds) after dismissal unless force is true
    if (!force && _lastDismissedTime != null) {
      final diff = DateTime.now().difference(_lastDismissedTime!).inSeconds;
      if (diff < 2) return false;
    }

    _isSheetOpen = true;

    try {
      final isPermanentlyDenied = status.isPermanentlyDenied;
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (ctx) => _buildPermissionBottomSheet(
          ctx,
          isPermanentlyDenied: isPermanentlyDenied,
          onGranted: onGranted,
        ),
      );
    } finally {
      _lastDismissedTime = DateTime.now();
      _isSheetOpen = false;
    }

    final postStatus = await Permission.notification.status;
    if (postStatus.isGranted) {
      onGranted?.call();
      return true;
    }
    return false;
  }

  static Widget _buildPermissionBottomSheet(
    BuildContext context, {
    required bool isPermanentlyDenied,
    VoidCallback? onGranted,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 44,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            const SizedBox(height: 24),
            Container(
              width: 72,
              height: 72,
              decoration: const BoxDecoration(
                color: Color(0xFFEEF2FF),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.notifications_active_rounded,
                size: 40,
                color: Color(0xFF4F46E5),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              isPermanentlyDenied ? 'Enable in Settings' : 'Allow Notifications',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: Color(0xFF0F172A),
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              isPermanentlyDenied
                  ? 'Notifications are turned off in your phone settings. Please enable them to receive calls and messages.'
                  : 'Enable notifications so you never miss an incoming call or a new message.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14.5,
                color: Colors.grey.shade600,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4F46E5),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                ),
                onPressed: () async {
                  Navigator.pop(context);
                  if (isPermanentlyDenied) {
                    openAppSettings();
                  } else {
                    final newStatus = await Permission.notification.request();
                    if (newStatus.isGranted) {
                      onGranted?.call();
                    }
                  }
                },
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      isPermanentlyDenied ? Icons.settings_rounded : Icons.check_circle_outline_rounded,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isPermanentlyDenied ? 'Open Settings' : 'Allow Notifications',
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(
                  'Maybe Later',
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 14.5, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Future<bool> checkAndRequestMicrophonePermission() async {
    final status = await Permission.microphone.status;
    if (!status.isGranted) {
      final newStatus = await Permission.microphone.request();
      return newStatus.isGranted;
    }
    return true;
  }
}
