package com.sajnire.app

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.util.Log
import com.google.android.gms.tasks.Tasks
import com.google.firebase.database.FirebaseDatabase
import com.google.firebase.database.ServerValue
import java.util.concurrent.TimeUnit

class AppCloseService : Service() {
    private var expertId: String? = null
    private var gender: String? = null
    private var language: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        intent?.let {
            expertId = it.getStringExtra("expertId")
            gender = it.getStringExtra("gender")
            language = it.getStringExtra("language")
            Log.d("AppCloseService", "Started for expertId: $expertId, gender: $gender, language: $language")
        }
        return START_NOT_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        
        val componentName = rootIntent?.component?.className ?: ""
        Log.d("AppCloseService", "onTaskRemoved triggered. componentName: $componentName")
        
        // Only proceed if the task removed is the main app task, NOT the CallKit activity.
        if (componentName.contains("CallkitIncomingActivity")) {
            Log.d("AppCloseService", "Ignoring onTaskRemoved because it is just CallKit finishing.")
            return
        }

        // 1. Immediately flag SharedPreferences synchronously so FCM background handler suppresses any ring/call
        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            prefs.edit()
                .putBoolean("flutter.isExpertOnline", false)
                .putBoolean("flutter.isAppSwipedAway", true)
                .commit()
            Log.d("AppCloseService", "Set flutter.isAppSwipedAway=true and flutter.isExpertOnline=false in prefs")
        } catch (e: Exception) {
            Log.e("AppCloseService", "Error updating SharedPreferences onTaskRemoved", e)
        }

        expertId?.let { uid ->
            Log.d("AppCloseService", "Setting offline and stopping service for expertId: $uid")
            try {
                val db = FirebaseDatabase.getInstance("https://zegochat-c44b0.asia-southeast1.firebasedatabase.app")
                
                // 2. Set status to offline in RTDB with await
                val updates = mapOf<String, Any>(
                    "isOnline" to false,
                    "status" to "offline",
                    "callStatus" to "offline",
                    "lastChanged" to ServerValue.TIMESTAMP
                )
                try {
                    val statusTask = db.getReference("status/$uid").updateChildren(updates)
                    Tasks.await(statusTask, 2, TimeUnit.SECONDS)
                } catch (te: Exception) {
                    Log.w("AppCloseService", "Timeout or error updating RTDB status: ${te.message}")
                }
                
                // 3. Explicitly remove from the matchmaking queue with await
                if (gender != null && language != null) {
                    try {
                        val queueRef = db.getReference("queues/${gender}_${language}/$uid")
                        val qTask = queueRef.removeValue()
                        Tasks.await(qTask, 2, TimeUnit.SECONDS)
                    } catch (te: Exception) {
                        Log.w("AppCloseService", "Timeout or error removing from queue: ${te.message}")
                    }
                }

                // 4. Also remove from expert_buckets in the new RTDB
                try {
                    val db2 = FirebaseDatabase.getInstance("https://zegochat-c44b0-4cbfb.asia-southeast1.firebasedatabase.app")
                    val bLang = language?.lowercase()?.trim() ?: "hindi"
                    val bTask = db2.getReference("expert_buckets/$bLang/$uid").removeValue()
                    Tasks.await(bTask, 2, TimeUnit.SECONDS)
                } catch (te: Exception) {
                    Log.w("AppCloseService", "Timeout or error removing from expert_buckets: ${te.message}")
                }

                // 5. Stop the flutter_background_service to ensure RTDB disconnects properly
                val backgroundServiceIntent = Intent()
                backgroundServiceIntent.setClassName(this, "id.flutter.flutter_background_service.BackgroundService")
                stopService(backgroundServiceIntent)

            } catch (e: Exception) {
                Log.e("AppCloseService", "Error setting offline", e)
            }
        }
        stopSelf()
    }
}
