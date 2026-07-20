package com.brandmen.ads;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * Поднимает управление при любом событии «устройство ожило»:
 *   • BOOT_COMPLETED / LOCKED_BOOT_COMPLETED — обычная загрузка (в т.ч. после
 *     полной разрядки и зарядки) и Direct Boot до разблокировки;
 *   • QUICKBOOT_POWERON (HTC/MIUI) — «быстрое» включение части прошивок;
 *   • MY_PACKAGE_REPLACED — после обновления самого приложения;
 *   • ACTION_POWER_CONNECTED — воткнули зарядку: страховочный нудж сервиса.
 *
 * Поднимаем HTTP-сервер сразу — планшет управляем по сети ещё до появления
 * плеера на экране. Заодно применяем kiosk-политики и планируем watchdog.
 */
public class BootReceiver extends BroadcastReceiver {
    static final String ACTION_BOOT_RECOVERY = "com.brandmen.ads.BOOT_RECOVERY";

    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent.getAction();
        if (action == null) return;

        boolean lockedBoot =
                "android.intent.action.LOCKED_BOOT_COMPLETED".equals(action);
        boolean bootOrRecovery = Intent.ACTION_BOOT_COMPLETED.equals(action)
                || "android.intent.action.QUICKBOOT_POWERON".equals(action)
                || "com.htc.intent.action.QUICKBOOT_POWERON".equals(action)
                || Intent.ACTION_MY_PACKAGE_REPLACED.equals(action)
                || Intent.ACTION_USER_UNLOCKED.equals(action)
                || Intent.ACTION_USER_PRESENT.equals(action)
                || ACTION_BOOT_RECOVERY.equals(action);
        boolean powerOnly = Intent.ACTION_POWER_CONNECTED.equals(action);
        if (!lockedBoot && !bootOrRecovery && !powerOnly) return;

        try { Kiosk.applyPolicies(context); } catch (Exception ignored) {}
        if (lockedBoot) {
            // Credential-encrypted storage и ролики до первого unlock ещё
            // недоступны. Здесь только включаем экран; USER_UNLOCKED /
            // BOOT_COMPLETED затем безопасно поднимут сервис и Activity.
            try { Kiosk.wakeScreen(context); } catch (Exception ignored) {}
            return;
        }
        if (bootOrRecovery) {
            // MIUI часто принимает BOOT_COMPLETED, но оставляет экран выключенным
            // и блокирует обычный startActivity. Сначала будим дисплей, затем
            // foreground-сервис сам несколько раз поднимает Activity.
            try { Kiosk.wakeScreen(context); } catch (Exception ignored) {}
            try { PlayerService.startAndLaunch(context); } catch (Exception ignored) {}
        } else {
            try { PlayerService.start(context); } catch (Exception ignored) {}
        }

        // Независимая страховка от убийства процесса сразу после boot. Для
        // recovery-события новые будильники не создаём, иначе был бы цикл.
        boolean initialRecovery = Intent.ACTION_BOOT_COMPLETED.equals(action)
                || "android.intent.action.QUICKBOOT_POWERON".equals(action)
                || "com.htc.intent.action.QUICKBOOT_POWERON".equals(action)
                || Intent.ACTION_MY_PACKAGE_REPLACED.equals(action);
        if (initialRecovery) {
            Kiosk.scheduleBootRecovery(context);
        }
    }
}
