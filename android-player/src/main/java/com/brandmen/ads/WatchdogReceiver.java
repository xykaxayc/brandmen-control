package com.brandmen.ads;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/**
 * Будильник-сторож: периодически (и после ACTION_POWER_CONNECTED) убеждается,
 * что foreground-сервис управления жив, и перепланирует следующий тик.
 * START_STICKY + device owner покрывают почти всё; этот ресивер — страховка для
 * прошивок, которые всё равно прибивают сервис (MIUI и т.п.).
 */
public class WatchdogReceiver extends BroadcastReceiver {
    static final String ACTION_TICK = "com.brandmen.ads.WATCHDOG_TICK";

    @Override
    public void onReceive(Context context, Intent intent) {
        try {
            if (Kiosk.isPlaybackEnabled(context)) {
                PlayerService.startAndLaunch(context);
            } else {
                PlayerService.start(context);
            }
        } catch (Exception ignored) {}
        // Страховка на случай, если сервис был убит и его быстрый цикл не работал:
        // проверяем сеть и чиним WiFi прямо из будильника.
        try { NetworkWatchdog.checkAndHeal(context); } catch (Exception ignored) {}
        // Перепланировать следующий тик (будильник одноразовый).
        Kiosk.scheduleWatchdog(context);
    }
}
