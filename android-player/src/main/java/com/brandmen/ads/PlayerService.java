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
import android.content.SharedPreferences;
import java.net.HttpURLConnection;
import java.net.URL;
import org.json.JSONObject;
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
    private static final String ACTION_AUTO_LAUNCH =
            "com.brandmen.ads.AUTO_LAUNCH";
    static final String CHANNEL_ID = "brandmen_player";
    static final int NOTI_ID = 1;
    // Отдельный HIGH-канал для full-screen-intent — им поднимаем плеер на экран
    // из фона (без разрешения «поверх других приложений»).
    static final String FSI_CHANNEL_ID = "brandmen_fsi";
    static final int FSI_NOTI_ID = 2;
    private static final String ADS_DIR = "/sdcard/Movies/ads";

    private MediaServer mediaServer;
    private CommandPoller commandPoller;
    private android.net.wifi.WifiManager.WifiLock wifiLock;
    private android.net.wifi.WifiManager.MulticastLock multicastLock;
    private AudioManager audioManager;
    private android.app.admin.DevicePolicyManager dpm;
    private ComponentName adminComponent;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private static final long REGISTER_INTERVAL_MS = 60_000L;
    private final Runnable registerWithControl = new Runnable() {
        @Override public void run() {
            registerWithKnownControl();
            mainHandler.postDelayed(this, REGISTER_INTERVAL_MS);
        }
    };

    /** Быстрый цикл само-восстановления сети, пока сервис жив (backstop — watchdog-будильник). */
    private static final long NET_HEAL_INTERVAL_MS = 60_000L;
    private final Runnable netHeal = new Runnable() {
        @Override public void run() {
            try { NetworkWatchdog.checkAndHeal(PlayerService.this); } catch (Exception ignored) {}
            mainHandler.postDelayed(this, NET_HEAL_INTERVAL_MS);
        }
    };

    @Override
    public void onCreate() {
        super.onCreate();
        audioManager = (AudioManager) getSystemService(AUDIO_SERVICE);
        dpm = (android.app.admin.DevicePolicyManager) getSystemService(DEVICE_POLICY_SERVICE);
        adminComponent = new ComponentName(this, DeviceAdminReceiver.class);

        startForegroundNotification();
        acquireLocks();
        // Применяем kiosk-политики (если device owner) и планируем watchdog —
        // идемпотентно, повторные старты сервиса безопасны.
        try { Kiosk.applyPolicies(this); } catch (Exception ignored) {}
        // Само-восстановление сети: сразу и затем раз в минуту, пока сервис жив.
        mainHandler.postDelayed(netHeal, NET_HEAL_INTERVAL_MS);
        try {
            mediaServer = new MediaServer(this, ADS_DIR, this);
            mediaServer.start();
        } catch (Exception e) {
            android.util.Log.e("PlayerService", "MediaServer start failed: " + e.getMessage());
        }
        // Outbound-канал: планшет сам забирает команды с сервера (управляем даже
        // без прямого доступа из локалки).
        try {
            commandPoller = new CommandPoller(this, this, mainHandler);
            commandPoller.start();
        } catch (Exception e) {
            android.util.Log.e("PlayerService", "CommandPoller start failed: " + e.getMessage());
        }
        // Сообщаем пульту актуальный IP не только из Activity. Это работает
        // после загрузки и при смене DHCP-адреса, даже если UI выгружен.
        mainHandler.postDelayed(registerWithControl, 3_000L);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent != null && ACTION_AUTO_LAUNCH.equals(intent.getAction())) {
            // Повторы нужны для MIUI: первая попытка часто приходится на ещё
            // заблокированный launcher сразу после boot.
            long[] delays = {500L, 3_000L, 10_000L};
            for (long delay : delays) {
                mainHandler.postDelayed(() -> {
                    Kiosk.wakeScreen(PlayerService.this);
                    sendCmd("launch");
                }, delay);
            }
        }
        // Перезапуск системой (после kill) — сервис должен подняться сам.
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }

    @Override
    public void onDestroy() {
        mainHandler.removeCallbacks(netHeal);
        mainHandler.removeCallbacks(registerWithControl);
        if (commandPoller != null) commandPoller.stop();
        if (mediaServer != null) mediaServer.stop();
        releaseLocks();
        super.onDestroy();
    }

    private void registerWithKnownControl() {
        new Thread(() -> {
            HttpURLConnection conn = null;
            try {
                SharedPreferences prefs =
                        getSharedPreferences("BrandmenPrefs", MODE_PRIVATE);
                String serverIp = prefs.getString("server_ip", "");
                if (serverIp == null || serverIp.trim().isEmpty()) return;

                DeploymentManager identity = new DeploymentManager(this);
                JSONObject registration = new JSONObject();
                registration.put("name",
                        android.os.Build.MANUFACTURER + " " + android.os.Build.MODEL);
                registration.put("device_id", identity.deviceId());
                registration.put("api_token", identity.apiToken());

                byte[] data = registration.toString().getBytes("UTF-8");
                URL url = new URL("http://" + serverIp + ":5010/api/register");
                conn = (HttpURLConnection) url.openConnection();
                conn.setRequestMethod("POST");
                conn.setDoOutput(true);
                conn.setConnectTimeout(3_000);
                conn.setReadTimeout(3_000);
                conn.setRequestProperty("Content-Type", "application/json");
                conn.setFixedLengthStreamingMode(data.length);
                conn.getOutputStream().write(data);
                int code = conn.getResponseCode();
                if (code != 200 && code != 403) {
                    android.util.Log.w("PlayerService",
                            "Control registration failed: HTTP " + code);
                }
            } catch (Exception e) {
                // Пульт может быть выключен — это штатно; повторим через минуту.
                android.util.Log.d("PlayerService",
                        "Control registration deferred: " + e.getMessage());
            } finally {
                if (conn != null) conn.disconnect();
            }
        }, "ControlRegistration").start();
    }

    /** Запускает foreground-сервис. Безопасно вызывать многократно. */
    static void start(Context ctx) {
        Intent i = new Intent(ctx, PlayerService.class);
        startIntent(ctx, i);
    }

    static void startAndLaunch(Context ctx) {
        Intent i = new Intent(ctx, PlayerService.class)
                .setAction(ACTION_AUTO_LAUNCH);
        startIntent(ctx, i);
    }

    private static void startIntent(Context ctx, Intent i) {
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
            // HIGH-канал для FSI — нужен высокий приоритет, иначе full-screen
            // intent не сработает.
            NotificationChannel fsi = new NotificationChannel(
                    FSI_CHANNEL_ID, "Вывод плеера на экран",
                    NotificationManager.IMPORTANCE_HIGH);
            fsi.setShowBadge(false);
            nm.createNotificationChannel(fsi);
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

    /**
     * Доставляет команду живой Activity и ГАРАНТИРОВАННО выводит плеер на экран.
     *
     * Прямой startActivity из фонового сервиса на Android 12+/MIUI блокируется
     * (плеер остаётся в фоне, на экране — рабочий стол). Поэтому дополнительно
     * публикуем full-screen-intent уведомление: система сама поднимает Activity
     * на экран БЕЗ разрешения «поверх других приложений» (механизм будильников/
     * звонилок). Прямой запуск оставляем для быстрого пути, когда плеер уже на
     * переднем плане или разрешение «поверх» выдано.
     */
    private void sendCmd(String cmd) {
        Intent i = new Intent(this, MainActivity.class)
                .setAction(MainActivity.CMD_ACTION)
                .putExtra("cmd", cmd)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        // 1) Быстрый путь.
        try { startActivity(i); }
        catch (Exception e) { android.util.Log.w("PlayerService", "sendCmd " + cmd + ": " + e.getMessage()); }
        // 2) Надёжный путь из фона — FSI-уведомление.
        fsiForeground(i, 100);
    }

    /**
     * Надёжно выводит указанную Activity на экран из фона через full-screen-intent
     * уведомление — система поднимает её сама, без разрешения «поверх других
     * приложений». Используется и для команд плеера, и для окна установки APK.
     */
    private void fsiForeground(Intent activityIntent, int reqCode) {
        try {
            int piFlags = PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= 23) piFlags |= PendingIntent.FLAG_IMMUTABLE;
            PendingIntent pi = PendingIntent.getActivity(this, reqCode, activityIntent, piFlags);
            Notification.Builder b = (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
                    ? new Notification.Builder(this, FSI_CHANNEL_ID)
                    : new Notification.Builder(this).setPriority(Notification.PRIORITY_HIGH);
            Notification n = b
                    .setContentTitle("Brandmen Ads")
                    .setContentText("Вывод плеера на экран…")
                    .setSmallIcon(android.R.drawable.btn_star_big_on)
                    .setCategory(Notification.CATEGORY_CALL)
                    .setFullScreenIntent(pi, true)
                    .setAutoCancel(true)
                    .build();
            NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
            nm.notify(FSI_NOTI_ID, n);
            // Уведомление своё дело сделало (подняло экран) — убираем через 3 с.
            mainHandler.postDelayed(() -> {
                try { nm.cancel(FSI_NOTI_ID); } catch (Exception ignored) {}
            }, 3000);
        } catch (Exception e) {
            android.util.Log.w("PlayerService", "fsiForeground: " + e.getMessage());
        }
    }

    @Override public void onWake() { sendCmd("wake"); }
    @Override public void onLaunch() { sendCmd("launch"); }
    @Override public void onRestart() { sendCmd("restart"); }

    @Override public void onClearDeviceOwner() {
        boolean ok = Kiosk.clearDeviceOwner(this);
        android.util.Log.w("PlayerService", "clearDeviceOwner: " + ok);
    }

    @Override public void onReboot() {
        boolean ok = Kiosk.reboot(this);
        android.util.Log.w("PlayerService", "reboot: " + ok);
    }

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
    @Override public int getPlaybackPositionMs() { MainActivity a = MainActivity.peek(); return a != null ? a.getPlaybackPositionMs() : -1; }

    @Override public void onInstallApk(File apkFile) {
        if (new DeploymentManager(this).isOperationActive()) {
            android.util.Log.w("PlayerService",
                    "installApk отложен: идёт операция с контентом");
            return;
        }
        // Выводим плеер на передний план (FSI), чтобы системное окно установки
        // показалось поверх экрана даже без разрешения «поверх других приложений».
        Intent open = new Intent(this, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_SINGLE_TOP);
        try { startActivity(open); } catch (Exception ignored) {}
        fsiForeground(open, 102);
        // Небольшая задержка — даём Activity выйти на экран, затем ставим APK,
        // чтобы окно подтверждения установки гарантированно оказалось на переднем плане.
        mainHandler.postDelayed(() -> installApk(this, apkFile), 1200);
    }

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
