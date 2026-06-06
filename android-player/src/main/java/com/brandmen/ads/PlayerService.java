package com.brandmen.ads;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInstaller;
import android.media.AudioManager;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.provider.Settings;
import java.io.File;
import java.io.FileInputStream;
import java.io.OutputStream;

/**
 * Foreground-сервис: держит HTTP-сервер (порт 5011) и Wi-Fi-лок живыми
 * независимо от Activity. Даже если MIUI выгрузит плеер с экрана, сервис
 * (START_STICKY) переживает это и поднимается заново — планшет остаётся
 * доступен по сети для управления и синхронизации контента БЕЗ ADB.
 *
 * Управление, которому нужен UI (запуск/перезапуск/пробуждение, яркость,
 * статус воспроизведения), делегируется живой Activity. Остальное —
 * файлы/синк/установка/громкость/блокировка экрана — сервис делает сам.
 */
public class PlayerService extends Service implements MediaServer.ControlCallback {
    static final String CHANNEL_ID = "brandmen_player";
    static final int NOTI_ID = 1;
    private static final String ADS_DIR = "/sdcard/Movies/ads";

    private MediaServer mediaServer;
    private android.net.wifi.WifiManager.WifiLock wifiLock;
    private android.net.wifi.WifiManager.MulticastLock multicastLock;
    private AudioManager audioManager;
    private android.app.admin.DevicePolicyManager dpm;
    private ComponentName adminComponent;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());

    @Override
    public void onCreate() {
        super.onCreate();
        audioManager = (AudioManager) getSystemService(AUDIO_SERVICE);
        dpm = (android.app.admin.DevicePolicyManager) getSystemService(DEVICE_POLICY_SERVICE);
        adminComponent = new ComponentName(this, DeviceAdminReceiver.class);

        startForegroundNotification();
        acquireLocks();
        try {
            mediaServer = new MediaServer(this, ADS_DIR, this);
            mediaServer.start();
        } catch (Exception e) {
            android.util.Log.e("PlayerService", "MediaServer start failed: " + e.getMessage());
        }
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        // Перезапуск системой (после kill) — сервис должен подняться сам.
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }

    @Override
    public void onDestroy() {
        if (mediaServer != null) mediaServer.stop();
        releaseLocks();
        super.onDestroy();
    }

    /** Запускает foreground-сервис. Безопасно вызывать многократно. */
    static void start(Context ctx) {
        Intent i = new Intent(ctx, PlayerService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            ctx.startForegroundService(i);
        } else {
            ctx.startService(i);
        }
    }

    private void startForegroundNotification() {
        NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel ch = new NotificationChannel(
                    CHANNEL_ID, "Brandmen Ads", NotificationManager.IMPORTANCE_MIN);
            ch.setShowBadge(false);
            nm.createNotificationChannel(ch);
        }
        Intent open = new Intent(this, MainActivity.class).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        int piFlags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= 23) piFlags |= PendingIntent.FLAG_IMMUTABLE;
        PendingIntent pi = PendingIntent.getActivity(this, 0, open, piFlags);
        Notification.Builder b = (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        Notification n = b
                .setContentTitle("Brandmen Ads")
                .setContentText("Плеер активен")
                .setSmallIcon(android.R.drawable.btn_star_big_on)
                .setOngoing(true)
                .setContentIntent(pi)
                .build();
        // targetSdk 33 → тип foreground-сервиса не требуется даже на Android 14+.
        startForeground(NOTI_ID, n);
    }

    private void acquireLocks() {
        try {
            android.net.wifi.WifiManager wifi = (android.net.wifi.WifiManager)
                    getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            wifiLock = wifi.createWifiLock(
                    android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF, "brandmen_wifi_lock");
            wifiLock.setReferenceCounted(false);
            wifiLock.acquire();
            multicastLock = wifi.createMulticastLock("brandmen_mcast");
            multicastLock.setReferenceCounted(false);
            multicastLock.acquire();
        } catch (Exception e) {
            android.util.Log.e("PlayerService", "locks: " + e.getMessage());
        }
    }

    private void releaseLocks() {
        try { if (wifiLock != null && wifiLock.isHeld()) wifiLock.release(); } catch (Exception ignored) {}
        try { if (multicastLock != null && multicastLock.isHeld()) multicastLock.release(); } catch (Exception ignored) {}
    }

    // ---- ControlCallback ----

    /** Доставляет команду живой Activity (или поднимает её), чтобы выполнить UI-действие. */
    private void sendCmd(String cmd) {
        Intent i = new Intent(this, MainActivity.class)
                .setAction(MainActivity.CMD_ACTION)
                .putExtra("cmd", cmd)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        try { startActivity(i); }
        catch (Exception e) { android.util.Log.w("PlayerService", "sendCmd " + cmd + ": " + e.getMessage()); }
    }

    @Override public void onWake() { sendCmd("wake"); }
    @Override public void onLaunch() { sendCmd("launch"); }
    @Override public void onRestart() { sendCmd("restart"); }

    @Override public void onSleep() {
        try { if (dpm != null && dpm.isAdminActive(adminComponent)) dpm.lockNow(); }
        catch (Exception e) { android.util.Log.w("PlayerService", "sleep: " + e.getMessage()); }
    }

    @Override public void onVolume(int level) {
        int max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, Math.max(0, Math.min(level, max)), 0);
    }
    @Override public int getVolume() { return audioManager.getStreamVolume(AudioManager.STREAM_MUSIC); }
    @Override public int getVolumeMax() { return audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC); }

    @Override public void onBrightness(int level) {
        MainActivity act = MainActivity.peek();
        if (act != null) { mainHandler.post(() -> act.onBrightness(level)); return; }
        try {
            Settings.System.putInt(getContentResolver(),
                    Settings.System.SCREEN_BRIGHTNESS, Math.max(1, Math.min(level, 255)));
        } catch (Exception ignored) {}
    }
    @Override public int getBrightness() {
        MainActivity act = MainActivity.peek();
        if (act != null) return act.getBrightness();
        try { return Settings.System.getInt(getContentResolver(), Settings.System.SCREEN_BRIGHTNESS, 128); }
        catch (Exception e) { return 128; }
    }

    @Override public int getCurrentIndex() { MainActivity a = MainActivity.peek(); return a != null ? a.getCurrentIndex() : -1; }
    @Override public int getPlaylistCount() { MainActivity a = MainActivity.peek(); return a != null ? a.getPlaylistCount() : 0; }
    @Override public String getCurrentName() { MainActivity a = MainActivity.peek(); return a != null ? a.getCurrentName() : ""; }
    @Override public boolean isPlaying() { MainActivity a = MainActivity.peek(); return a != null && a.isPlaying(); }

    @Override public void onInstallApk(File apkFile) { installApk(this, apkFile); }

    /**
     * Установка APK через PackageInstaller. Тихо, если приложение — device owner;
     * иначе система показывает окно подтверждения (PendingIntent ведёт в MainActivity).
     */
    static void installApk(Context ctx, File apkFile) {
        new Thread(() -> {
            try {
                PackageInstaller pi = ctx.getPackageManager().getPackageInstaller();
                PackageInstaller.SessionParams params = new PackageInstaller.SessionParams(
                        PackageInstaller.SessionParams.MODE_FULL_INSTALL);
                int sessionId = pi.createSession(params);
                try (PackageInstaller.Session session = pi.openSession(sessionId)) {
                    try (FileInputStream is = new FileInputStream(apkFile);
                         OutputStream os = session.openWrite("base.apk", 0, apkFile.length())) {
                        byte[] buf = new byte[65536];
                        int n;
                        while ((n = is.read(buf)) != -1) os.write(buf, 0, n);
                        session.fsync(os);
                    }
                    Intent intent = new Intent(ctx, MainActivity.class)
                            .setAction(MainActivity.INSTALL_RESULT_ACTION);
                    int flags = PendingIntent.FLAG_UPDATE_CURRENT;
                    if (Build.VERSION.SDK_INT >= 31) flags |= PendingIntent.FLAG_MUTABLE;
                    PendingIntent pending = PendingIntent.getActivity(ctx, sessionId, intent, flags);
                    session.commit(pending.getIntentSender());
                }
            } catch (Exception e) {
                android.util.Log.e("PlayerService", "installApk: " + e.getMessage());
            }
        }, "InstallApk").start();
    }
}
