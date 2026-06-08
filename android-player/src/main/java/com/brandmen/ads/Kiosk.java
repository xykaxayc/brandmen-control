package com.brandmen.ads;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.app.admin.DevicePolicyManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.PowerManager;
import android.os.SystemClock;
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
    private static final int WATCHDOG_REQUEST = 0xB12D;
    /** Период watchdog: неточный (не требует SCHEDULE_EXACT_ALARM), но пробивает Doze. */
    private static final long WATCHDOG_INTERVAL_MS = 15 * 60 * 1000L;

    private Kiosk() {}

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

        // Авто-выдача runtime-разрешений (хранилище и т.д.) — без диалогов клиенту.
        try {
            if (Build.VERSION.SDK_INT >= 23) {
                dpm.setPermissionPolicy(admin, DevicePolicyManager.PERMISSION_POLICY_AUTO_GRANT);
            }
        } catch (Exception ignored) {}

        // Миграция: снимаем жёсткий киоск, если его включала прошлая версия,
        // чтобы планшет снова можно было свернуть/закрыть/удалить вручную.
        try { dpm.setLockTaskPackages(admin, new String[0]); } catch (Exception ignored) {}
        try { dpm.clearPackagePersistentPreferredActivities(admin, pkg); } catch (Exception ignored) {}
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
