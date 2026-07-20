package com.brandmen.ads;

import android.app.admin.DevicePolicyManager;
import android.content.Context;
import android.content.SharedPreferences;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkInfo;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.SystemClock;

/**
 * Сеть-сторож: следит, что планшет ОНЛАЙН, и сам поднимает WiFi, если тот отвалился.
 * Это главное лекарство от боли «планшет потерял WiFi и не возвращается», когда
 * физического доступа (USB) к нему нет.
 *
 * Эскалация при отсутствии сети:
 *   1) включить WiFi (setWifiEnabled — работает для device owner и до Android 10);
 *   2) переассоциироваться с сохранённой точкой (disconnect + reconnect/reassociate);
 *   3) если сети нет дольше {@link #REBOOT_AFTER_MS} и мы device owner —
 *      перезагрузить устройство ({@code dpm.reboot}). Планшеты на постоянной
 *      зарядке, поэтому ребут безопасен.
 *
 * Плюс — плановый НОЧНОЙ ребут (device owner) раз в сутки, чтобы гарантированно
 * сбрасывать накопившиеся зависания WiFi/прошивки.
 *
 * Защита от цикла перезагрузок: не чаще одного ребута в {@link #MIN_REBOOT_GAP_MS},
 * не в первые {@link #MIN_UPTIME_MS} после загрузки (даём сети шанс подняться самой).
 */
final class NetworkWatchdog {
    private static final String TAG = "NetWatchdog";
    private static final String PREFS = "netwatch";
    private static final String K_DOWN_SINCE = "down_since_elapsed";
    private static final String K_LAST_REBOOT = "last_reboot_wall";
    private static final String K_LAST_NIGHTLY = "last_nightly_ymd";

    /** Нет сети дольше этого → ребут (только device owner). */
    private static final long REBOOT_AFTER_MS = 10 * 60 * 1000L;
    /** Не чаще одного ребута в этот интервал (анти-цикл). */
    private static final long MIN_REBOOT_GAP_MS = 60 * 60 * 1000L;
    /** Не трогаем ребутом первые N после загрузки — даём сети подняться самой. */
    private static final long MIN_UPTIME_MS = 5 * 60 * 1000L;
    /** Час планового ночного ребута (местное время устройства). */
    private static final int NIGHTLY_HOUR = 5;

    private NetworkWatchdog() {}

    /**
     * «Онлайн» = либо WiFi связан с точкой и имеет IP (нам важна достижимость в
     * локалке, а не наличие интернета — в барбершопе интернета может и не быть),
     * либо активная сеть системы заявляет интернет (Ethernet-донгл и т.п.).
     */
    static boolean isOnline(Context ctx) {
        return isWifiUsable(ctx) || activeNetworkConnected(ctx);
    }

    private static boolean isWifiUsable(Context ctx) {
        try {
            WifiManager wifi = (WifiManager) ctx.getApplicationContext()
                    .getSystemService(Context.WIFI_SERVICE);
            if (wifi == null || !wifi.isWifiEnabled()) return false;
            WifiInfo info = wifi.getConnectionInfo();
            // Связаны с точкой (есть networkId) и получили IP.
            return info != null && info.getNetworkId() != -1 && info.getIpAddress() != 0;
        } catch (Exception e) {
            return false;
        }
    }

    private static boolean activeNetworkConnected(Context ctx) {
        try {
            ConnectivityManager cm = (ConnectivityManager) ctx.getApplicationContext()
                    .getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm == null) return false;
            if (Build.VERSION.SDK_INT >= 23) {
                Network n = cm.getActiveNetwork();
                if (n == null) return false;
                NetworkCapabilities caps = cm.getNetworkCapabilities(n);
                return caps != null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET);
            }
            NetworkInfo ni = cm.getActiveNetworkInfo();
            return ni != null && ni.isConnected();
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * Проверить связь и при необходимости чинить. Вызывается из foreground-сервиса
     * (раз в минуту) и из watchdog-будильника (раз в 15 мин — на случай, если
     * сервис всё-таки убили). Идемпотентно и безопасно для частого вызова.
     */
    static void checkAndHeal(Context ctx) {
        Context app = ctx.getApplicationContext();
        SharedPreferences sp = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE);

        maybeNightlyReboot(app, sp);

        if (isOnline(app)) {
            if (sp.contains(K_DOWN_SINCE)) sp.edit().remove(K_DOWN_SINCE).apply();
            return;
        }

        long now = SystemClock.elapsedRealtime();
        long downSince = sp.getLong(K_DOWN_SINCE, 0L);
        // downSince > now означает, что был ребут (elapsedRealtime сбросился) —
        // считаем отсчёт заново.
        if (downSince == 0L || downSince > now) {
            downSince = now;
            sp.edit().putLong(K_DOWN_SINCE, downSince).apply();
            android.util.Log.w(TAG, "сеть пропала — начинаю восстановление WiFi");
        }

        healWifi(app);

        long downMs = now - downSince;
        if (downMs >= REBOOT_AFTER_MS) {
            rebootIfOwner(app, sp, "нет сети " + (downMs / 60000) + " мин");
        }
    }

    /** Включает WiFi и переподключает к сохранённой точке. */
    private static void healWifi(Context app) {
        try {
            WifiManager wifi = (WifiManager) app.getSystemService(Context.WIFI_SERVICE);
            if (wifi == null) return;
            if (!wifi.isWifiEnabled()) {
                try { wifi.setWifiEnabled(true); } catch (Exception ignored) {}
            }
            // Переассоциация: дизассоциируемся и просим переподключиться к сети.
            // На Android 10+ методы работают только для device owner/системы —
            // на обычном планшете просто ничего не делают (безопасно).
            try { wifi.disconnect(); } catch (Exception ignored) {}
            try { wifi.reconnect(); } catch (Exception ignored) {}
            try { wifi.reassociate(); } catch (Exception ignored) {}
        } catch (Exception e) {
            android.util.Log.w(TAG, "healWifi: " + e.getMessage());
        }
    }

    /** Плановый ночной ребут (device owner), не чаще одного раза в сутки. */
    private static void maybeNightlyReboot(Context app, SharedPreferences sp) {
        try {
            if (!Kiosk.isDeviceOwner(app)) return;
            java.util.Calendar c = java.util.Calendar.getInstance();
            if (c.get(java.util.Calendar.HOUR_OF_DAY) != NIGHTLY_HOUR) return;
            String ymd = new java.text.SimpleDateFormat("yyyyMMdd", java.util.Locale.US)
                    .format(c.getTime());
            if (ymd.equals(sp.getString(K_LAST_NIGHTLY, ""))) return; // уже перезагружались сегодня
            sp.edit().putString(K_LAST_NIGHTLY, ymd).apply();
            rebootIfOwner(app, sp, "плановый ночной ребут");
        } catch (Exception ignored) {}
    }

    /** Ребут с защитой от цикла (для авто-эскалации сети и ночного ребута). */
    static void rebootIfOwner(Context ctx, SharedPreferences sp, String reason) {
        try {
            Context app = ctx.getApplicationContext();
            if (new DeploymentManager(app).isOperationActive()) {
                android.util.Log.w(TAG, "ребут отложен: идёт операция с контентом");
                return;
            }
            if (Build.VERSION.SDK_INT < 24 || !Kiosk.isDeviceOwner(app)) {
                android.util.Log.w(TAG, "нужен ребут (" + reason + "), но недоступно (не owner / старый API)");
                return;
            }
            if (SystemClock.elapsedRealtime() < MIN_UPTIME_MS) return; // только что загрузились
            long wall = System.currentTimeMillis();
            long last = sp.getLong(K_LAST_REBOOT, 0L);
            if (last != 0L && Math.abs(wall - last) < MIN_REBOOT_GAP_MS) return; // анти-цикл
            sp.edit().putLong(K_LAST_REBOOT, wall).apply();
            android.util.Log.w(TAG, "РЕБУТ: " + reason);
            DevicePolicyManager dpm = Kiosk.dpm(app);
            if (dpm != null) dpm.reboot(Kiosk.admin(app));
        } catch (Exception e) {
            android.util.Log.w(TAG, "reboot: " + e.getMessage());
        }
    }
}
