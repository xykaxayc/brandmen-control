package com.brandmen.ads;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.app.admin.DevicePolicyManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.SharedPreferences;
import android.os.Build;
import android.os.PowerManager;
import android.os.SystemClock;
import android.os.UserManager;
import android.provider.Settings;

/**
 * Надёжный автозапуск и аптайм плеера БЕЗ жёсткого киоска — планшет остаётся
 * управляемым вручную (можно свернуть, закрыть, удалить).
 *
 *   • Любой планшет: watchdog-будильник + foreground-сервис поднимают сервер
 *     управления после загрузки/разрядки и если прошивка убила процесс.
 *   • Если планшет провижен как DEVICE OWNER (опционально, для надёжного
 *     автозапуска на MIUI без ручного «Автозапуска»): дополнительно экран не
 *     гаснет на зарядке и runtime-разрешения выдаются без диалогов. LockTask и
 *     прочий жёсткий киоск НЕ включаются.
 *
 * Провижининг device owner (опционально, на чистом устройстве без аккаунтов):
 *   adb shell dpm set-device-owner com.brandmen.ads/.DeviceAdminReceiver
 * Снять:
 *   adb shell dpm remove-active-admin com.brandmen.ads/.DeviceAdminReceiver
 */
final class Kiosk {
    private static final String TAG = "Kiosk";
    private static final String PLAYER_PREFS = "BrandmenPrefs";
    private static final String PLAYBACK_ENABLED = "playback_enabled";
    private static final int WATCHDOG_REQUEST = 0xB12D;
    private static final int BOOT_RECOVERY_REQUEST = 0xB130;
    /** Период watchdog: неточный (не требует SCHEDULE_EXACT_ALARM), но пробивает Doze. */
    private static final long WATCHDOG_INTERVAL_MS = 15 * 60 * 1000L;

    private Kiosk() {}

    /**
     * Желаемое состояние рекламы хранится в device-protected storage, чтобы
     * BootReceiver мог прочитать его до первого разблокирования после перезагрузки.
     */
    private static SharedPreferences playbackPrefs(Context ctx) {
        Context app = ctx.getApplicationContext();
        if (Build.VERSION.SDK_INT >= 24) {
            Context directBoot = app.createDeviceProtectedStorageContext();
            SharedPreferences prefs =
                    directBoot.getSharedPreferences(PLAYER_PREFS, Context.MODE_PRIVATE);
            if (!prefs.contains(PLAYBACK_ENABLED)) {
                try {
                    UserManager users =
                            (UserManager) app.getSystemService(Context.USER_SERVICE);
                    if (users == null || users.isUserUnlocked()) {
                        SharedPreferences legacy =
                                app.getSharedPreferences(PLAYER_PREFS, Context.MODE_PRIVATE);
                        if (legacy.contains(PLAYBACK_ENABLED)) {
                            prefs.edit().putBoolean(PLAYBACK_ENABLED,
                                    legacy.getBoolean(PLAYBACK_ENABLED, true)).commit();
                        }
                    }
                } catch (Exception ignored) {}
            }
            return prefs;
        }
        return app.getSharedPreferences(PLAYER_PREFS, Context.MODE_PRIVATE);
    }

    static boolean isPlaybackEnabled(Context ctx) {
        return playbackPrefs(ctx).getBoolean(PLAYBACK_ENABLED, true);
    }

    static void setPlaybackEnabled(Context ctx, boolean enabled) {
        playbackPrefs(ctx).edit().putBoolean(PLAYBACK_ENABLED, enabled).commit();
        // Оставляем совместимую копию для старых версий при откате APK.
        ctx.getApplicationContext().getSharedPreferences(PLAYER_PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean(PLAYBACK_ENABLED, enabled).apply();
    }

    static ComponentName admin(Context ctx) {
        return new ComponentName(ctx.getApplicationContext(), DeviceAdminReceiver.class);
    }

    static DevicePolicyManager dpm(Context ctx) {
        return (DevicePolicyManager) ctx.getApplicationContext()
                .getSystemService(Context.DEVICE_POLICY_SERVICE);
    }

    static boolean isDeviceOwner(Context ctx) {
        try {
            DevicePolicyManager dpm = dpm(ctx);
            return dpm != null && dpm.isDeviceOwnerApp(ctx.getPackageName());
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * Снимает с приложения статус device owner и все его политики/ограничения
     * (включая no_factory_reset). Вызвать может только сам owner. После этого
     * планшет — обычный, и в Безопасности MIUI можно вручную включить «Автозапуск».
     */
    static boolean clearDeviceOwner(Context ctx) {
        try {
            DevicePolicyManager dpm = dpm(ctx);
            if (dpm != null && isDeviceOwner(ctx)) {
                dpm.clearDeviceOwnerApp(ctx.getPackageName());
                return true;
            }
        } catch (Exception e) {
            android.util.Log.w(TAG, "clearDeviceOwner: " + e.getMessage());
        }
        return false;
    }

    /**
     * Применяет все политики выделенного устройства. Идемпотентно — безопасно
     * вызывать на каждой загрузке и старте сервиса. На не-device-owner просто
     * планирует watchdog и выходит.
     */
    static void applyPolicies(Context ctx) {
        scheduleWatchdog(ctx);
        if (!isDeviceOwner(ctx)) return;

        DevicePolicyManager dpm = dpm(ctx);
        ComponentName admin = admin(ctx);
        Context app = ctx.getApplicationContext();
        String pkg = app.getPackageName();

        // Полезные политики БЕЗ жёсткого киоска: планшет остаётся управляемым
        // вручную (можно свернуть/закрыть), но автозапуск и аптайм надёжнее.

        // Экран не гаснет, пока устройство на зарядке (AC/USB/беспроводная).
        try {
            int plugged = android.os.BatteryManager.BATTERY_PLUGGED_AC
                    | android.os.BatteryManager.BATTERY_PLUGGED_USB
                    | android.os.BatteryManager.BATTERY_PLUGGED_WIRELESS;
            dpm.setGlobalSetting(admin, Settings.Global.STAY_ON_WHILE_PLUGGED_IN,
                    String.valueOf(plugged));
        } catch (Exception ignored) {}

        // На выделенном рекламном планшете системный keyguard не должен
        // задерживать автозапуск после перезагрузки. Метод безопасно вернёт
        // false, если пользователь настроил защищённый PIN/пароль.
        try {
            if (Build.VERSION.SDK_INT >= 23) {
                dpm.setKeyguardDisabled(admin, true);
            }
        } catch (Exception ignored) {}

        // Авто-выдача runtime-разрешений (хранилище и т.д.) — без диалогов клиенту.
        try {
            if (Build.VERSION.SDK_INT >= 23) {
                dpm.setPermissionPolicy(admin, DevicePolicyManager.PERMISSION_POLICY_AUTO_GRANT);
            }
        } catch (Exception ignored) {}

        // Brandmen становится постоянным HOME только на выделенном Device Owner.
        // Это штатный Android-механизм для корпоративного устройства: после
        // загрузки и при нажатии Home система сама открывает плеер, без хрупких
        // full-screen уведомлений MIUI.
        try {
            IntentFilter home = new IntentFilter(Intent.ACTION_MAIN);
            home.addCategory(Intent.CATEGORY_HOME);
            home.addCategory(Intent.CATEGORY_DEFAULT);
            dpm.addPersistentPreferredActivity(
                    admin, home, new ComponentName(app, MainActivity.class));
        } catch (Exception e) {
            android.util.Log.w(TAG, "persistent HOME: " + e.getMessage());
        }

        // Жёсткий LockTask не нужен: управление и системные настройки остаются
        // доступны, но Home всегда возвращает на рекламный плеер.
        try { dpm.setLockTaskPackages(admin, new String[0]); } catch (Exception ignored) {}
        try { dpm.setUninstallBlocked(admin, pkg, false); } catch (Exception ignored) {}
        try {
            if (Build.VERSION.SDK_INT >= 21) {
                dpm.clearUserRestriction(admin, "no_safe_boot");
                dpm.clearUserRestriction(admin, "no_factory_reset");
                dpm.clearUserRestriction(admin, "no_add_user");
            }
        } catch (Exception ignored) {}
    }

    /**
     * Немедленный ребут по команде оператора (device owner). В отличие от
     * авто-эскалации сети — без анти-цикла: раз попросили, значит надо. Вернёт
     * false, если не device owner или API старше 24 (тогда перезагрузить нельзя).
     */
    static boolean reboot(Context ctx) {
        try {
            Context app = ctx.getApplicationContext();
            if (new DeploymentManager(app).isOperationActive()) {
                android.util.Log.w(TAG, "reboot отложен: идёт операция с контентом");
                return false;
            }
            if (Build.VERSION.SDK_INT < 24 || !isDeviceOwner(app)) return false;
            DevicePolicyManager dpm = dpm(app);
            if (dpm == null) return false;
            dpm.reboot(admin(app));
            return true;
        } catch (Exception e) {
            android.util.Log.w(TAG, "reboot: " + e.getMessage());
            return false;
        }
    }

    /**
     * Watchdog: неточный будильник, который периодически поднимает сервис, если
     * система его всё-таки прибила. Пробивает Doze (setAndAllowWhileIdle) и не
     * требует разрешения SCHEDULE_EXACT_ALARM. Перепланируется при каждом срабатывании.
     */
    static void scheduleWatchdog(Context ctx) {
        try {
            Context app = ctx.getApplicationContext();
            AlarmManager am = (AlarmManager) app.getSystemService(Context.ALARM_SERVICE);
            if (am == null) return;
            Intent i = new Intent(app, WatchdogReceiver.class).setAction(WatchdogReceiver.ACTION_TICK);
            int flags = PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= 31) flags |= PendingIntent.FLAG_IMMUTABLE;
            PendingIntent pi = PendingIntent.getBroadcast(app, WATCHDOG_REQUEST, i, flags);
            long at = SystemClock.elapsedRealtime() + WATCHDOG_INTERVAL_MS;
            if (Build.VERSION.SDK_INT >= 23) {
                am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi);
            } else {
                am.set(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi);
            }
        } catch (Exception ignored) {}
    }

    /** Немедленно включает дисплей; не зависит от живой Activity или ADB. */
    static void wakeScreen(Context ctx) {
        try {
            PowerManager pm = (PowerManager) ctx.getApplicationContext()
                    .getSystemService(Context.POWER_SERVICE);
            if (pm == null) return;
            PowerManager.WakeLock lock = pm.newWakeLock(
                    PowerManager.SCREEN_BRIGHT_WAKE_LOCK
                            | PowerManager.ACQUIRE_CAUSES_WAKEUP
                            | PowerManager.ON_AFTER_RELEASE,
                    "Brandmen::BootWake");
            lock.acquire(30_000L);
        } catch (Exception ignored) {}
    }

    /**
     * Три независимые попытки после boot. Даже если MIUI сразу убил процесс,
     * явный AlarmManager снова поднимет receiver, foreground-service и экран.
     */
    static void scheduleBootRecovery(Context ctx) {
        try {
            Context app = ctx.getApplicationContext();
            AlarmManager am = (AlarmManager) app.getSystemService(Context.ALARM_SERVICE);
            if (am == null) return;
            // Не создаём частую очередь запусков: MIUI плохо переносит несколько
            // full-screen intents подряд. Каждая попытка внутри сервиса сначала
            // проверит, не играет ли Activity уже сейчас.
            long[] delays = {30_000L, 120_000L};
            for (int index = 0; index < delays.length; index++) {
                Intent i = new Intent(app, BootReceiver.class)
                        .setAction(BootReceiver.ACTION_BOOT_RECOVERY);
                int flags = PendingIntent.FLAG_UPDATE_CURRENT;
                if (Build.VERSION.SDK_INT >= 31) flags |= PendingIntent.FLAG_IMMUTABLE;
                PendingIntent pi = PendingIntent.getBroadcast(
                        app, BOOT_RECOVERY_REQUEST + index, i, flags);
                long at = SystemClock.elapsedRealtime() + delays[index];
                if (Build.VERSION.SDK_INT >= 23 && index == delays.length - 1) {
                    am.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi);
                } else {
                    am.set(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, pi);
                }
            }
        } catch (Exception ignored) {}
    }

    /**
     * Фолбэк для НЕ-device-owner: просит пользователя исключить приложение из
     * оптимизации батареи (системный диалог). Безопасно вызывать на каждом старте —
     * если уже исключено, ничего не показывает.
     */
    static void requestBatteryExemptionIfNeeded(android.app.Activity act) {
        try {
            if (Build.VERSION.SDK_INT < 23) return;
            if (isDeviceOwner(act)) return;
            PowerManager pm = (PowerManager) act.getSystemService(Context.POWER_SERVICE);
            String pkg = act.getPackageName();
            if (pm != null && !pm.isIgnoringBatteryOptimizations(pkg)) {
                Intent i = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                        .setData(android.net.Uri.parse("package:" + pkg));
                act.startActivity(i);
            }
        } catch (Exception ignored) {}
    }
}
