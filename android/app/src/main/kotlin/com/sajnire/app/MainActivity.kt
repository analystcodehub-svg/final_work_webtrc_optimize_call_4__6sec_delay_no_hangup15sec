package com.sajnire.app

import android.app.Activity
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.os.Build
import android.view.WindowManager
import android.widget.Toast
import java.io.File
import kotlin.system.exitProcess
import com.google.android.gms.auth.api.identity.GetPhoneNumberHintIntentRequest
import com.google.android.gms.auth.api.identity.Identity
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.sajnire.app/auth"
    private val REQUEST_PHONE_HINT = 1001
    private var pendingResult: MethodChannel.Result? = null

    // Create notification channels natively so they exist even BEFORE Flutter code runs.
    // This is critical for showing FCM notifications in killed/terminated app state.
    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

            // Messages channel — used for chat message notifications
            val messagesChannel = NotificationChannel(
                "messages_channel",
                "Messages",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Chat message notifications"
                enableVibration(true)
            }
            manager.createNotificationChannel(messagesChannel)

            // Calls channel — used for incoming call notifications (WhatsApp style)
            val callsChannel = NotificationChannel(
                "calls_channel",
                "Incoming Calls",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Incoming call notifications"
                enableVibration(true)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                setBypassDnd(true)
            }
            manager.createNotificationChannel(callsChannel)
        }
    }

    private var initialCallRoomId: String? = null

    private fun extractCallRoomId(intent: Intent?): String? {
        if (intent == null) return null
        val action = intent.action ?: ""
        if (action.endsWith(".ACTION_CALL_ACCEPT") || action == "com.hiennv.flutter_callkit_incoming.ACTION_CALL_ACCEPT") {
            val data = intent.getBundleExtra("EXTRA_CALLKIT_CALL_DATA")
            return data?.getString("EXTRA_CALLKIT_ID") ?: intent.getStringExtra("EXTRA_CALLKIT_ID")
        }
        return null
    }

    private fun turnScreenOnAndShowWhenLocked() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
            keyguardManager?.requestDismissKeyguard(this, null)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
            )
        }
        // Keep screen awake during in-app call activities (prevents 15s screen timeout)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun isEmulator(): Boolean {
        val fingerPrint = Build.FINGERPRINT.lowercase()
        val model = Build.MODEL.lowercase()
        val manufacturer = Build.MANUFACTURER.lowercase()
        val brand = Build.BRAND.lowercase()
        val device = Build.DEVICE.lowercase()
        val product = Build.PRODUCT.lowercase()
        val hardware = Build.HARDWARE.lowercase()
        val board = Build.BOARD.lowercase()
        val bootloader = Build.BOOTLOADER.lowercase()

        return (brand.startsWith("generic") && device.startsWith("generic"))
                || fingerPrint.startsWith("generic")
                || fingerPrint.startsWith("unknown")
                || fingerPrint.contains("google_sdk")
                || fingerPrint.contains("emulator")
                || fingerPrint.contains("simulator")
                || fingerPrint.contains("vbox")
                || (fingerPrint.contains("test-keys") && (model.contains("google_sdk") || model.contains("emulator")))
                || hardware.contains("goldfish")
                || hardware.contains("ranchu")
                || hardware.contains("vbox86")
                || hardware.contains("nox")
                || hardware.contains("bst")
                || hardware.contains("qemu")
                || hardware.contains("ttvm")
                || model.contains("google_sdk")
                || model.contains("emulator")
                || model.contains("android sdk built for x86")
                || model.contains("droid4x")
                || model.contains("tiantian")
                || model.contains("andy")
                || model.contains("mumu")
                || manufacturer.contains("genymotion")
                || manufacturer.contains("bluestacks")
                || manufacturer.contains("bignox")
                || manufacturer.contains("nox")
                || manufacturer.contains("mumu")
                || product.contains("sdk_google")
                || product.contains("google_sdk")
                || product.contains("sdk")
                || product.contains("sdk_x86")
                || product.contains("sdk_gphone64_arm64")
                || product.contains("vbox86p")
                || product.contains("emulator")
                || product.contains("simulator")
                || product.contains("nox")
                || product.contains("bluestacks")
                || product.contains("mumu")
                || board.contains("nox")
                || bootloader.contains("nox")
                || File("/dev/socket/qemud").exists()
                || File("/dev/qemu_pipe").exists()
                || File("/system/bin/androVM-prop").exists()
                || File("/system/bin/microvirt-prop").exists()
                || File("/system/bin/nox-prop").exists()
                || File("/system/bin/ttVM-prop").exists()
                || File("/system/bin/bstfolder").exists()
                || File("/data/data/com.bluestacks.home").exists()
                || File("/data/data/com.bignox.app").exists()
                || File("/data/data/com.microvirt.tools").exists()
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        if (isEmulator()) {
            Toast.makeText(
                this,
                "This application cannot be run on a PC emulator.",
                Toast.LENGTH_LONG
            ).show()
            finishAffinity()
            exitProcess(0)
            return
        }
        turnScreenOnAndShowWhenLocked()
        initialCallRoomId = extractCallRoomId(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Create channels FIRST before Flutter engine starts
        createNotificationChannels()
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "getInitialCallId") {
                result.success(initialCallRoomId)
                initialCallRoomId = null
            } else if (call.method == "requestPhoneHint") {
                // Return immediately if there is already a pending request
                if (pendingResult != null) {
                    result.error("ALREADY_ACTIVE", "A phone hint request is already active", null)
                    return@setMethodCallHandler
                }
                
                pendingResult = result
                val request = GetPhoneNumberHintIntentRequest.builder().build()
                
                Identity.getSignInClient(this)
                    .getPhoneNumberHintIntent(request)
                    .addOnSuccessListener { pendingIntentResponse ->
                        try {
                            startIntentSenderForResult(
                                pendingIntentResponse.intentSender,
                                REQUEST_PHONE_HINT,
                                null, 0, 0, 0
                            )
                        } catch (e: IntentSender.SendIntentException) {
                            pendingResult?.error("HINT_FAILED", "Failed to start intent sender: ${e.message}", null)
                            pendingResult = null
                        }
                    }
                    .addOnFailureListener { e ->
                        pendingResult?.error("HINT_UNAVAILABLE", "Phone hint not available: ${e.message}", null)
                        pendingResult = null
                    }
            } else if (call.method == "bringToForeground") {
                val intent = Intent(context, MainActivity::class.java)
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
                startActivity(intent)
                result.success(null)
            } else if (call.method == "setAppCloseHandler") {
                val expertId = call.argument<String>("expertId")
                val gender = call.argument<String>("gender")
                val language = call.argument<String>("language")
                val serviceIntent = Intent(context, AppCloseService::class.java)
                serviceIntent.putExtra("expertId", expertId)
                serviceIntent.putExtra("gender", gender)
                serviceIntent.putExtra("language", language)
                context.startService(serviceIntent)
                result.success(null)
            } else if (call.method == "clearAppCloseHandler") {
                val serviceIntent = Intent(context, AppCloseService::class.java)
                context.stopService(serviceIntent)
                result.success(null)
            } else if (call.method == "dismissCallKitScreen") {
                try {
                    val intent = Intent("${packageName}.com.hiennv.flutter_callkit_incoming.ACTION_ENDED_CALL_INCOMING").apply {
                        putExtra("ACCEPTED", false)
                        `package` = packageName
                    }
                    sendBroadcast(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("ERROR", e.message, null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onResume() {
        super.onResume()
        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            prefs.edit().putBoolean("flutter.isAppSwipedAway", false).apply()
        } catch (_: Exception) {}
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        turnScreenOnAndShowWhenLocked()
        val callRoomId = extractCallRoomId(intent)
        if (!callRoomId.isNullOrEmpty()) {
            flutterEngine?.dartExecutor?.binaryMessenger?.let { messenger ->
                MethodChannel(messenger, CHANNEL).invokeMethod("onCallAcceptFallback", callRoomId)
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        
        if (requestCode == REQUEST_PHONE_HINT) {
            if (resultCode == Activity.RESULT_OK && data != null) {
                try {
                    val phoneNumber = Identity.getSignInClient(this).getPhoneNumberFromIntent(data)
                    pendingResult?.success(phoneNumber)
                } catch (e: Exception) {
                    pendingResult?.error("EXTRACT_FAILED", e.message, null)
                }
            } else {
                pendingResult?.error("CANCELLED", "User cancelled or failed", null)
            }
            pendingResult = null
        }
    }
}
