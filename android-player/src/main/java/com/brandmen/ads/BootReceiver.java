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
    @Override
    public void onReceive(Context context, Intent intent) {
        String action = intent.getAction();
        if (action == null) return;

        boolean wake = Intent.ACTION_BOOT_COMPLETED.equals(action)
                || "android.intent.action.LOCKED_BOOT_COMPLETED".equals(action)
                || "android.intent.action.QUICKBOOT_POWERON".equals(action)
                || "com.htc.intent.action.QUICKBOOT_POWERON".equals(action)
                || Intent.ACTION_MY_PACKAGE_REPLACED.equals(action)
                || Intent.ACTION_POWER_CONNECTED.equals(action);
        if (!wake) return;

        try { Kiosk.applyPolicies(context); } catch (Exception ignored) {}
        try { PlayerService.start(context); } catch (Exception ignored) {}

        // На зарядку UI не вытаскиваем (экран мог быть выключен намеренно);
        // на загрузке/обновлении — открываем плеер.
        if (!Intent.ACTION_POWER_CONNECTED.equals(action)) {
            try {
                Intent i = new Intent(context, MainActivity.class);
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                context.startActivity(i);
            } catch (Exception ignored) {}
        }
    }
}
