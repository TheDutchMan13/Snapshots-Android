package io.github.thedutchman13.snapshots

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Android 13 and newer show the "Backing up" notification only with the user's permission.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "snapshots/notifications").setMethodCallHandler { call, result ->
            if (call.method != "ask") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            if (Build.VERSION.SDK_INT >= 33 &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
            ) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4712)
            }
            result.success(null)
        }
    }
}
