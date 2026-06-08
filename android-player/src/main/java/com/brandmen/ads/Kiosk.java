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
 * Централизованная логика «выделенного устройства» (COSU / kiosk).
 *
 * Стратегия — правильное + удобное решение с мягкой деградацией:
 *   • Новый/сброшенный планшет, провиженный как DEVICE OWNER, получает
 *     bulletproof-режим: автозапуск гарантирован, force-stop запрещён,
 *     LockTask/киоск, авто-выдача разрешений, экран не гаснет на зарядке.
 *   • Уже развёрнутый планшет (без device owner) продолжает работать на
 *     watchdog-будильнике + foreground-сервисе — без factory reset.
 *
 * Провижининг device owner (один раз, на чистом устройстве без аккаунтов):
 *   adb shell dpm set-device-owner com.brandmen.ads/.DeviceAdminReceiver
 * Снять (для разработки):
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

        // 1. LockTask — разрешаем нашему пакету входить в киоск без подтверждений.
        try { dpm.setLockTaskPackages(admin, new String[]{pkg}); } catch (Exception ignored) {}

        // 2. Авто-выдача всех runtime-разрешений (хранилище и т.д.).
        try {
            if (Build.VERSION.SDK_INT >= 23) {
                dpm.setPermissionPolicy(admin, DevicePolicyManager.PERMISSION_POLICY_AUTO_GRANT);
            }
        } catch (Exception ignored) {}

        // 3. Экран не гаснет, пока устройство на зарядке (AC/USB/беспроводная).
        try {
            int plugged = android.os.BatteryManager.BATTERY_PLUGGED_AC
                    | android.os.BatteryManager.BATTERY_PLUGGED_USB
                    | android.os.BatteryManager.BATTERY_PLUGGED_WIRELESS;
            dpm.setGlobalSetting(admin, Settings.Global.STAY_ON_WHILE_PLUGGED_IN,
                    String.valueOf(plugged));
        } catch (Exception ignored) {}

        // 4. Делаем приложение домашним лаунчером — после reboot и нажатия Home
        //    система молча возвращается в плеер (без выбора лаунчера).
        try {
            android.content.IntentFilter home = new android.content.IntentFilter(Intent.ACTION_MAIN);
            home.addCategory(Intent.CATEGORY_HOME);
            home.addCategory(Intent.CATEGORY_DEFAULT);
            dpm.addPersistentPreferredActivity(admin, home,
                    new ComponentName(pkg, MainActivity.class.getName()));
        } catch (Exception ignored) {}

        // 5. Запрещаем пользователю выгрузить/удалить/сбросить приложение и
        //    обойти киоск через безопасный режим/factory reset.
        try {
            dpm.setUninstallBlocked(admin, pkg, true);
            addRestriction(dpm, admin, "no_safe_boot");
            addRestriction(dpm, admin, "no_factory_reset");
            addRestriction(dpm, admin, "no_add_user");
        } catch (Exception ignored) {}
    }

    private static void addRestriction(DevicePolicyManager dpm, ComponentName admin, String key) {
        try {
            if (Build.VERSION.SDK_INT >= 21) dpm.addUserRestriction(admin, key);
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
