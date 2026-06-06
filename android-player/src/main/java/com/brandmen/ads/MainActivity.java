package com.brandmen.ads;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageInstaller;
import android.graphics.Color;
import android.media.MediaPlayer;
import android.net.Uri;
import android.net.nsd.NsdManager;
import android.net.nsd.NsdServiceInfo;
import android.os.*;
import android.provider.Settings;
import android.view.*;
import android.widget.*;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

public class MainActivity extends Activity implements MediaServer.ControlCallback {
    private VideoView videoView;
    private List<File> videoFiles = new ArrayList<>();
    private int currentIndex = 0;
    private static final String ADS_DIR = "/sdcard/Movies/ads";
    private static final String PLAYLIST_FILE = ADS_DIR + "/playlist.m3u";
    
    private FrameLayout rootLayout;
    private LinearLayout controlsLayout;
    private LinearLayout playlistLayout;
    private TextView playPauseBtn;
    private TextView timeText;
    private TextView syncStatusView;
    private TextView recoveryView;
    private boolean userPaused = false;
    private ProgressBar progressBar;
    private SeekBar volumeBar;
    
    private boolean isControlsVisible = true;
    private boolean isPlaylistVisible = false;
    private Handler hideHandler = new Handler();
    private android.media.AudioManager audioManager;
    private SharedPreferences prefs;

    private NsdManager nsdManager;
    private NsdManager.DiscoveryListener discoveryListener;
    private static final String SERVICE_TYPE = "_brandmen._tcp.";
    private android.net.wifi.WifiManager.MulticastLock multicastLock;

    // Слабая ссылка на живую Activity — PlayerService делегирует ей UI-действия.
    private static java.lang.ref.WeakReference<MainActivity> sRef;
    public static final String CMD_ACTION = "com.brandmen.ads.CMD";
    static MainActivity peek() { return sRef == null ? null : sRef.get(); }

    private android.os.PowerManager.WakeLock wakeLock;
    private android.app.admin.DevicePolicyManager dpm;
    private android.content.ComponentName adminComponent;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        audioManager = (android.media.AudioManager) getSystemService(AUDIO_SERVICE);
        prefs = getSharedPreferences("BrandmenPrefs", MODE_PRIVATE);
        
        sRef = new java.lang.ref.WeakReference<>(this);

        android.net.wifi.WifiManager wifi = (android.net.wifi.WifiManager) getSystemService(Context.WIFI_SERVICE);
        multicastLock = wifi.createMulticastLock("brandmen_lock");
        multicastLock.setReferenceCounted(true);

        nsdManager = (NsdManager) getSystemService(Context.NSD_SERVICE);
        initializeDiscoveryListener();

        dpm = (android.app.admin.DevicePolicyManager) getSystemService(DEVICE_POLICY_SERVICE);
        adminComponent = new android.content.ComponentName(this, DeviceAdminReceiver.class);

        // HTTP-сервер и Wi-Fi-лок теперь живут в foreground-сервисе: он переживает
        // выгрузку плеера системой, поэтому планшет остаётся управляемым и
        // синхронизируемым по сети даже без открытого UI и без ADB.
        try {
            PlayerService.start(this);
        } catch (Exception e) {
            android.util.Log.e("MainActivity", "PlayerService start failed: " + e.getMessage());
        }

        rootLayout = new FrameLayout(this);
        rootLayout.setBackgroundColor(Color.BLACK);
        setContentView(rootLayout);

        videoView = new VideoView(this);
        rootLayout.addView(videoView, new FrameLayout.LayoutParams(-1, -1, Gravity.CENTER));

        // Оверлей прогресса синхронизации поверх видео.
        syncStatusView = new TextView(this);
        syncStatusView.setTextColor(Color.WHITE);
        syncStatusView.setTextSize(18);
        syncStatusView.setGravity(Gravity.CENTER);
        syncStatusView.setBackgroundColor(Color.parseColor("#CC000000"));
        syncStatusView.setPadding(60, 40, 60, 40);
        syncStatusView.setVisibility(View.GONE);
        rootLayout.addView(syncStatusView,
                new FrameLayout.LayoutParams(-2, -2, Gravity.CENTER));

        // Заглушка вместо чёрного экрана, когда нет контента/сети.
        recoveryView = new TextView(this);
        recoveryView.setTextColor(Color.parseColor("#66FFFFFF"));
        recoveryView.setTextSize(22);
        recoveryView.setGravity(Gravity.CENTER);
        recoveryView.setText("Brandmen Ads\n\nНет роликов для показа.\nДобавьте контент в приложении.");
        recoveryView.setVisibility(View.GONE);
        rootLayout.addView(recoveryView,
                new FrameLayout.LayoutParams(-1, -1, Gravity.CENTER));

        setupUI();
        setupPlaylistUI();
        
        videoView.setOnCompletionListener(mp -> { currentIndex++; playNext(); });
        videoView.setOnErrorListener((mp, what, extra) -> { currentIndex++; playNext(); return true; });
        rootLayout.setOnClickListener(v -> { if (isPlaylistVisible) hidePlaylist(); else toggleControls(); });

        checkPermissions();
        startProgressUpdater();
        startWatchdog();
        installCrashHandler();
        handleInstallResult(getIntent());
        handleCommand(getIntent());
        ensureOverlayPermission();
    }

    /**
     * Watchdog: раз в 20 сек проверяет, что плеер реально играет. Если нет
     * (и пользователь не ставил на паузу) — перезапускает воспроизведение.
     * Если позиция «застыла» (зависший ролик) — переходит к следующему.
     * Так планшет сам выходит из чёрного экрана/залипания без вмешательства.
     */
    private void startWatchdog() {
        final Handler h = new Handler();
        h.postDelayed(new Runnable() {
            int lastPos = -1;
            int stalls = 0;
            @Override public void run() {
                try {
                    if (!isPlaylistVisible && !userPaused && !videoFiles.isEmpty()) {
                        boolean playing = false;
                        try { playing = videoView.isPlaying(); } catch (Exception ignored) {}
                        if (!playing) {
                            android.util.Log.w("Watchdog", "не играет — перезапуск воспроизведения");
                            lastPos = -1; stalls = 0;
                            playNext();
                        } else {
                            int pos = -1;
                            try { pos = videoView.getCurrentPosition(); } catch (Exception ignored) {}
                            if (pos == lastPos && pos >= 0) {
                                stalls++;
                                if (stalls >= 2) {
                                    android.util.Log.w("Watchdog", "ролик завис — следующий");
                                    stalls = 0; lastPos = -1;
                                    currentIndex++;
                                    playNext();
                                }
                            } else {
                                stalls = 0; lastPos = pos;
                            }
                        }
                    }
                } catch (Exception e) {
                    android.util.Log.e("Watchdog", "ошибка: " + e.getMessage());
                }
                h.postDelayed(this, 20000);
            }
        }, 20000);
    }

    /**
     * Перехват необработанных исключений: пишем в лог и перепланируем запуск
     * Activity через AlarmManager, затем убиваем процесс — плеер сам
     * поднимется после краша, а не останется лежать.
     */
    private void installCrashHandler() {
        final Thread.UncaughtExceptionHandler def = Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler((thread, ex) -> {
            try {
                android.util.Log.e("MainActivity", "КРАШ: " + ex, ex);
                Intent restart = new Intent(this, MainActivity.class)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                int flags = PendingIntent.FLAG_ONE_SHOT;
                if (Build.VERSION.SDK_INT >= 23) flags |= PendingIntent.FLAG_IMMUTABLE;
                PendingIntent pi = PendingIntent.getActivity(this, 1, restart, flags);
                android.app.AlarmManager am =
                        (android.app.AlarmManager) getSystemService(ALARM_SERVICE);
                am.set(android.app.AlarmManager.RTC,
                        System.currentTimeMillis() + 1500, pi);
            } catch (Exception ignored) {
            } finally {
                if (def != null) def.uncaughtException(thread, ex);
                android.os.Process.killProcess(android.os.Process.myPid());
                System.exit(2);
            }
        });
    }

    /**
     * Разрешение «Показ поверх других приложений» нужно, чтобы PlayerService мог
     * вытащить плеер на экран по HTTP-команде из фона (Android 12+ иначе блокирует
     * фоновый запуск Activity). Спрашиваем один раз.
     */
    private void ensureOverlayPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return;
        if (Settings.canDrawOverlays(this)) return;
        if (prefs.getBoolean("overlay_asked", false)) return;
        prefs.edit().putBoolean("overlay_asked", true).apply();
        try {
            Intent i = new Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                    Uri.parse("package:" + getPackageName()));
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(i);
        } catch (Exception ignored) {}
    }

    @Override
    protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        handleInstallResult(intent);
        handleCommand(intent);
    }

    /** Команды от PlayerService (когда управление пришло по HTTP, а UI требует Activity). */
    private void handleCommand(Intent intent) {
        if (intent == null || !CMD_ACTION.equals(intent.getAction())) return;
        String cmd = intent.getStringExtra("cmd");
        if (cmd == null) return;
        switch (cmd) {
            case "wake": onWake(); break;
            case "launch": onLaunch(); break;
            case "restart": onRestart(); break;
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (multicastLock != null) multicastLock.acquire();
        if (nsdManager != null && discoveryListener != null) {
            try {
                nsdManager.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener);
            } catch (Exception e) {
                e.printStackTrace();
            }
        }
    }

    @Override
    protected void onPause() {
        if (nsdManager != null && discoveryListener != null) {
            try {
                nsdManager.stopServiceDiscovery(discoveryListener);
            } catch (Exception e) {
                e.printStackTrace();
            }
        }
        if (multicastLock != null && multicastLock.isHeld()) multicastLock.release();
        super.onPause();
    }

    private void initializeDiscoveryListener() {
        discoveryListener = new NsdManager.DiscoveryListener() {
            @Override
            public void onStartDiscoveryFailed(String serviceType, int errorCode) { 
                try { nsdManager.stopServiceDiscovery(this); } catch (Exception e) {}
            }
            @Override
            public void onStopDiscoveryFailed(String serviceType, int errorCode) {
                try { nsdManager.stopServiceDiscovery(this); } catch (Exception e) {}
            }
            @Override
            public void onDiscoveryStarted(String serviceType) {}
            @Override
            public void onDiscoveryStopped(String serviceType) {}

            @Override
            public void onServiceFound(NsdServiceInfo serviceInfo) {
                if (serviceInfo.getServiceType().contains("brandmen")) {
                    nsdManager.resolveService(serviceInfo, new NsdManager.ResolveListener() {
                        @Override
                        public void onResolveFailed(NsdServiceInfo serviceInfo, int errorCode) {}
                        @Override
                        public void onServiceResolved(NsdServiceInfo serviceInfo) {
                            final String host = serviceInfo.getHost().getHostAddress();
                            if (host != null) {
                                runOnUiThread(() -> {
                                    String currentIp = prefs.getString("server_ip", "");
                                    if (!host.equals(currentIp)) {
                                        prefs.edit().putString("server_ip", host).apply();
                                        Toast.makeText(MainActivity.this, "Сервер найден: " + host, Toast.LENGTH_SHORT).show();
                                    }
                                });
                                registerWithServer(host);
                            }
                        }
                    });
                }
            }

            @Override
            public void onServiceLost(NsdServiceInfo serviceInfo) {}
        };
    }

    private String getServerIp() {
        return prefs.getString("server_ip", "192.168.1.107");
    }

    private void setupUI() {
        controlsLayout = new LinearLayout(this);
        controlsLayout.setOrientation(LinearLayout.VERTICAL);
        controlsLayout.setGravity(Gravity.CENTER);
        controlsLayout.setPadding(35, 25, 35, 25);
        
        android.graphics.drawable.GradientDrawable shape = new android.graphics.drawable.GradientDrawable();
        shape.setColor(Color.parseColor("#CC000000"));
        shape.setCornerRadius(60);
        controlsLayout.setBackground(shape);

        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(1000, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.gravity = Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL;
        lp.bottomMargin = 50;
        rootLayout.addView(controlsLayout, lp);

        LinearLayout topRow = new LinearLayout(this);
        topRow.setOrientation(LinearLayout.HORIZONTAL);
        topRow.setGravity(Gravity.CENTER_VERTICAL);
        controlsLayout.addView(topRow);

        timeText = new TextView(this);
        timeText.setText("00:00 / 00:00");
        timeText.setTextColor(Color.WHITE);
        timeText.setTextSize(13);
        topRow.addView(timeText, new LinearLayout.LayoutParams(0, -2, 1));

        TextView syncBtn = new TextView(this);
        syncBtn.setText("🔄 Обновить");
        syncBtn.setTextColor(Color.parseColor("#34C759"));
        syncBtn.setTextSize(15);
        syncBtn.setPadding(15, 10, 15, 10);
        syncBtn.setOnClickListener(v -> startSync());
        topRow.addView(syncBtn);

        TextView listBtn = new TextView(this);
        listBtn.setText("☰ Список");
        listBtn.setTextColor(Color.parseColor("#007AFF"));
        listBtn.setTextSize(15);
        listBtn.setPadding(15, 10, 15, 10);
        listBtn.setOnClickListener(v -> showPlaylist());
        topRow.addView(listBtn);

        TextView settingsBtn = new TextView(this);
        settingsBtn.setText("⚙️");
        settingsBtn.setTextSize(18);
        settingsBtn.setPadding(15, 10, 15, 10);
        settingsBtn.setOnClickListener(v -> showSettingsDialog());
        topRow.addView(settingsBtn);

        TextView exitBtn = new TextView(this);
        exitBtn.setText("✕");
        exitBtn.setTextColor(Color.parseColor("#FF3B30"));
        exitBtn.setTextSize(20);
        exitBtn.setPadding(15, 10, 15, 10);
        exitBtn.setOnClickListener(v -> finish());
        topRow.addView(exitBtn);

        LinearLayout buttonsRow = new LinearLayout(this);
        buttonsRow.setOrientation(LinearLayout.HORIZONTAL);
        buttonsRow.setGravity(Gravity.CENTER);
        controlsLayout.addView(buttonsRow);

        TextView prevBtn = createStyledButton("⏮");
        prevBtn.setOnClickListener(v -> { currentIndex--; if (currentIndex < 0) currentIndex = Math.max(0, videoFiles.size() - 1); playNext(); });
        buttonsRow.addView(prevBtn);

        playPauseBtn = createStyledButton("⏸");
        playPauseBtn.setTextSize(50);
        playPauseBtn.setPadding(50, 5, 50, 5);
        playPauseBtn.setOnClickListener(v -> {
            if (videoView.isPlaying()) { videoView.pause(); playPauseBtn.setText("▶"); userPaused = true; }
            else { videoView.start(); playPauseBtn.setText("⏸"); userPaused = false; }
            resetHideTimer();
        });
        buttonsRow.addView(playPauseBtn);

        TextView nextBtn = createStyledButton("⏭");
        nextBtn.setOnClickListener(v -> { currentIndex++; playNext(); });
        buttonsRow.addView(nextBtn);

        progressBar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        controlsLayout.addView(progressBar, new LinearLayout.LayoutParams(-1, 8));

        LinearLayout volRow = new LinearLayout(this);
        volRow.setOrientation(LinearLayout.HORIZONTAL);
        volRow.setGravity(Gravity.CENTER_VERTICAL);
        volRow.setPadding(0, 15, 0, 0);
        controlsLayout.addView(volRow);

        TextView volIcon = new TextView(this); volIcon.setText("🔈"); volRow.addView(volIcon);
        volumeBar = new SeekBar(this);
        volumeBar.setMax(audioManager.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC));
        volumeBar.setProgress(audioManager.getStreamVolume(android.media.AudioManager.STREAM_MUSIC));
        volumeBar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar seekBar, int progress, boolean fromUser) {
                if (fromUser) audioManager.setStreamVolume(android.media.AudioManager.STREAM_MUSIC, progress, 0);
                resetHideTimer();
            }
            @Override public void onStartTrackingTouch(SeekBar seekBar) {}
            @Override public void onStopTrackingTouch(SeekBar seekBar) {}
        });
        volRow.addView(volumeBar, new LinearLayout.LayoutParams(0, -2, 1));
        TextView volMax = new TextView(this); volMax.setText("🔊"); volRow.addView(volMax);
    }

    private DiscoveryListener activeDiscovery;

    private void showSettingsDialog() {
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(50, 30, 50, 20);

        TextView ipLabel = new TextView(this);
        ipLabel.setText("IP адрес компьютера");
        ipLabel.setTextColor(Color.WHITE);
        ipLabel.setTextSize(13);
        content.addView(ipLabel);

        LinearLayout ipRow = new LinearLayout(this);
        ipRow.setOrientation(LinearLayout.HORIZONTAL);
        ipRow.setGravity(Gravity.CENTER_VERTICAL);
        content.addView(ipRow, new LinearLayout.LayoutParams(-1, -2));

        final EditText ipInput = new EditText(this);
        ipInput.setText(getServerIp());
        ipInput.setHint("192.168.1.xxx");
        ipInput.setTextColor(Color.WHITE);
        ipInput.setTextSize(16);
        ipRow.addView(ipInput, new LinearLayout.LayoutParams(0, -2, 1));

        final TextView findBtn = new TextView(this);
        findBtn.setText("🔍");
        findBtn.setTextColor(Color.parseColor("#007AFF"));
        findBtn.setTextSize(18);
        findBtn.setPadding(20, 10, 0, 10);
        findBtn.setOnClickListener(v -> startDiscovery(ipInput, findBtn));
        ipRow.addView(findBtn);

        final TextView searchStatus = new TextView(this);
        searchStatus.setText("mDNS обнаружение активно автоматически");
        searchStatus.setTextColor(Color.parseColor("#66FFFFFF"));
        searchStatus.setTextSize(11);
        content.addView(searchStatus, new LinearLayout.LayoutParams(-1, -2));

        // Разделитель 1
        content.addView(makeDivider());

        // Строка сопряжения
        LinearLayout pairRow = new LinearLayout(this);
        pairRow.setOrientation(LinearLayout.HORIZONTAL);
        pairRow.setGravity(Gravity.CENTER_VERTICAL);
        content.addView(pairRow, new LinearLayout.LayoutParams(-1, -2));

        final TextView pairStatus = new TextView(this);
        pairStatus.setText("Не добавлен в приложение");
        pairStatus.setTextColor(Color.parseColor("#99FFFFFF"));
        pairStatus.setTextSize(12);
        pairRow.addView(pairStatus, new LinearLayout.LayoutParams(0, -2, 1));

        final TextView pairBtn = new TextView(this);
        pairBtn.setText("🔗 Сопряжение");
        pairBtn.setTextColor(Color.parseColor("#007AFF"));
        pairBtn.setTextSize(13);
        pairBtn.setPadding(0, 10, 0, 10);
        pairBtn.setOnClickListener(v -> startPairingFlow(ipInput, pairBtn, pairStatus));
        pairRow.addView(pairBtn);

        // Разделитель 2
        content.addView(makeDivider());

        // Строка администратора устройства (для выключения экрана)
        if (dpm != null && !dpm.isAdminActive(adminComponent)) {
            LinearLayout adminRow = new LinearLayout(this);
            adminRow.setOrientation(LinearLayout.HORIZONTAL);
            adminRow.setGravity(Gravity.CENTER_VERTICAL);
            content.addView(adminRow, new LinearLayout.LayoutParams(-1, -2));

            TextView adminStatus = new TextView(this);
            adminStatus.setText("Выключение экрана недоступно");
            adminStatus.setTextColor(Color.parseColor("#FF9F0A"));
            adminStatus.setTextSize(12);
            adminRow.addView(adminStatus, new LinearLayout.LayoutParams(0, -2, 1));

            TextView adminBtn = new TextView(this);
            adminBtn.setText("Активировать");
            adminBtn.setTextColor(Color.parseColor("#007AFF"));
            adminBtn.setTextSize(13);
            adminBtn.setPadding(0, 10, 0, 10);
            adminBtn.setOnClickListener(v -> {
                Intent intent = new Intent(android.app.admin.DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN);
                intent.putExtra(android.app.admin.DevicePolicyManager.EXTRA_DEVICE_ADMIN, adminComponent);
                intent.putExtra(android.app.admin.DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                    "Нужно для удалённого выключения экрана");
                startActivity(intent);
            });
            adminRow.addView(adminBtn);
            content.addView(makeDivider());
        }

        // Строка обновления
        LinearLayout updateRow = new LinearLayout(this);
        updateRow.setOrientation(LinearLayout.HORIZONTAL);
        updateRow.setGravity(Gravity.CENTER_VERTICAL);
        content.addView(updateRow, new LinearLayout.LayoutParams(-1, -2));

        final TextView updateStatus = new TextView(this);
        updateStatus.setText("v" + MediaServer.VERSION);
        updateStatus.setTextColor(Color.parseColor("#99FFFFFF"));
        updateStatus.setTextSize(12);
        updateRow.addView(updateStatus, new LinearLayout.LayoutParams(0, -2, 1));

        final TextView updateBtn = new TextView(this);
        updateBtn.setText("Проверить обновление");
        updateBtn.setTextColor(Color.parseColor("#007AFF"));
        updateBtn.setTextSize(13);
        updateBtn.setPadding(0, 10, 0, 10);
        updateBtn.setOnClickListener(v -> checkUpdate(updateBtn, updateStatus));
        updateRow.addView(updateBtn);

        new AlertDialog.Builder(this)
            .setTitle("Настройки · v" + MediaServer.VERSION)
            .setView(content)
            .setPositiveButton("Сохранить", (dialog, which) -> {
                if (activeDiscovery != null) { activeDiscovery.cancel(); activeDiscovery = null; }
                String ip = ipInput.getText().toString().trim();
                if (ip.contains(":")) ip = ip.substring(0, ip.indexOf(':'));
                prefs.edit().putString("server_ip", ip).apply();
                Toast.makeText(this, "IP сохранен: " + ip, Toast.LENGTH_SHORT).show();
            })
            .setNegativeButton("Отмена", (dialog, which) -> {
                if (activeDiscovery != null) { activeDiscovery.cancel(); activeDiscovery = null; }
            })
            .show();
    }

    private void startDiscovery(EditText ipInput, TextView findBtn) {
        if (activeDiscovery != null) activeDiscovery.cancel();
        activeDiscovery = new DiscoveryListener();
        findBtn.setText("⏳");
        findBtn.setEnabled(false);
        activeDiscovery.findAsync(new DiscoveryListener.Callback() {
            @Override public void onFound(String ip) {
                runOnUiThread(() -> {
                    ipInput.setText(ip);
                    findBtn.setText("✓");
                    findBtn.setTextColor(Color.parseColor("#34C759"));
                    activeDiscovery = null;
                });
                registerWithServer(ip);
            }
            @Override public void onTimeout() {
                runOnUiThread(() -> {
                    findBtn.setText("🔍");
                    findBtn.setEnabled(true);
                    findBtn.setTextColor(Color.parseColor("#007AFF"));
                    Toast.makeText(MainActivity.this,
                            "Компьютер не найден. Проверьте WiFi.", Toast.LENGTH_SHORT).show();
                    activeDiscovery = null;
                });
            }
        });
    }

    private View makeDivider() {
        View div = new View(this);
        div.setBackgroundColor(Color.parseColor("#33FFFFFF"));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(-1, 1);
        lp.topMargin = 18;
        lp.bottomMargin = 14;
        div.setLayoutParams(lp);
        return div;
    }

    // Полный флоу сопряжения: пинг сохранённого IP → если недоступен, UDP-поиск → регистрация
    private void startPairingFlow(EditText ipInput, TextView btn, TextView status) {
        btn.setEnabled(false);
        btn.setText("⏳");
        status.setText("Ищу сервер...");
        status.setTextColor(Color.parseColor("#99FFFFFF"));

        new Thread(() -> {
            // Шаг 1: попробовать текущий IP из поля
            String savedIp = ipInput.getText().toString().trim();
            if (savedIp.contains(":")) savedIp = savedIp.substring(0, savedIp.indexOf(':'));
            String reachableIp = savedIp.isEmpty() ? null : tryPing(savedIp);

            // Шаг 2: если не пингуется — UDP broadcast
            if (reachableIp == null) {
                runOnUiThread(() -> status.setText("Не нашёл по IP, пробую поиск..."));
                reachableIp = udpDiscover();
            }

            if (reachableIp == null) {
                final String hint = savedIp.isEmpty()
                        ? "Убедитесь, что компьютер в той же сети"
                        : "Не удалось найти сервер (" + savedIp + ")";
                runOnUiThread(() -> {
                    status.setText(hint);
                    btn.setText("🔗 Повторить");
                    btn.setEnabled(true);
                });
                return;
            }

            final String foundIp = reachableIp;
            runOnUiThread(() -> {
                ipInput.setText(foundIp);
                status.setText("Найден " + foundIp + ", регистрирую...");
            });

            // Шаг 3: проверить паринг-мод и зарегистрироваться
            doPairingRequest(foundIp, btn, status);
        }, "PairingFlow").start();
    }

    private String tryPing(String ip) {
        try {
            java.net.URL url = new java.net.URL("http://" + ip + ":5010/api/ping");
            java.net.HttpURLConnection c = (java.net.HttpURLConnection) url.openConnection();
            c.setConnectTimeout(2000);
            c.setReadTimeout(2000);
            return c.getResponseCode() == 200 ? ip : null;
        } catch (Exception e) { return null; }
    }

    private String udpDiscover() {
        try (java.net.DatagramSocket socket = new java.net.DatagramSocket(DiscoveryListener.PORT)) {
            socket.setSoTimeout(6000);
            byte[] buf = new byte[512];
            java.net.DatagramPacket packet = new java.net.DatagramPacket(buf, buf.length);
            socket.receive(packet);
            String body = new String(packet.getData(), 0, packet.getLength(), "UTF-8");
            org.json.JSONObject json = new org.json.JSONObject(body);
            if ("brandmen-control".equals(json.optString("service"))) {
                return packet.getAddress().getHostAddress();
            }
        } catch (Exception ignored) {}
        return null;
    }

    private void doPairingRequest(String serverIp, TextView btn, TextView status) {
        try {
            // Проверяем режим сопряжения
            java.net.URL statusUrl = new java.net.URL("http://" + serverIp + ":5010/api/pairing-status");
            java.net.HttpURLConnection sc = (java.net.HttpURLConnection) statusUrl.openConnection();
            sc.setConnectTimeout(4000);
            sc.setReadTimeout(4000);
            java.io.BufferedReader br = new java.io.BufferedReader(
                    new java.io.InputStreamReader(sc.getInputStream(), "UTF-8"));
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = br.readLine()) != null) sb.append(line);
            boolean active = new org.json.JSONObject(sb.toString()).optBoolean("active", false);

            if (!active) {
                runOnUiThread(() -> {
                    status.setText("Нажмите «Режим сопряжения» на компьютере, потом повторите");
                    status.setTextColor(Color.parseColor("#FF9F0A"));
                    btn.setText("🔗 Повторить");
                    btn.setEnabled(true);
                });
                return;
            }

            // Отправляем регистрацию
            String deviceName = android.os.Build.MANUFACTURER + " " + android.os.Build.MODEL;
            String body2 = "{\"name\":\"" + deviceName.replace("\"", "") + "\"}";
            java.net.URL regUrl = new java.net.URL("http://" + serverIp + ":5010/api/register");
            java.net.HttpURLConnection rc = (java.net.HttpURLConnection) regUrl.openConnection();
            rc.setRequestMethod("POST");
            rc.setDoOutput(true);
            rc.setConnectTimeout(4000);
            rc.setReadTimeout(4000);
            rc.setRequestProperty("Content-Type", "application/json");
            byte[] data = body2.getBytes("UTF-8");
            rc.setRequestProperty("Content-Length", String.valueOf(data.length));
            rc.getOutputStream().write(data);
            int regCode = rc.getResponseCode();

            if (regCode == 200) {
                prefs.edit().putString("server_ip", serverIp).apply();
                runOnUiThread(() -> {
                    status.setText("✓ Добавлен в приложение");
                    status.setTextColor(Color.parseColor("#34C759"));
                    btn.setText("✓");
                    btn.setTextColor(Color.parseColor("#34C759"));
                    btn.setEnabled(false);
                });
            } else if (regCode == 403) {
                runOnUiThread(() -> {
                    status.setText("Режим сопряжения истёк — повторите на компьютере");
                    status.setTextColor(Color.parseColor("#FF9F0A"));
                    btn.setText("🔗 Повторить");
                    btn.setEnabled(true);
                });
            } else {
                runOnUiThread(() -> {
                    status.setText("Ошибка сервера: " + regCode);
                    btn.setText("🔗 Повторить");
                    btn.setEnabled(true);
                });
            }
        } catch (Exception e) {
            runOnUiThread(() -> {
                status.setText("Ошибка: " + e.getMessage());
                btn.setText("🔗 Повторить");
                btn.setEnabled(true);
            });
        }
    }

    private void registerWithServer(String serverIp) {
        String deviceName = android.os.Build.MANUFACTURER + " " + android.os.Build.MODEL;
        String body = "{\"name\":\"" + deviceName.replace("\"", "") + "\"}";
        new Thread(() -> {
            try {
                java.net.URL url = new java.net.URL("http://" + serverIp + ":5010/api/register");
                java.net.HttpURLConnection conn = (java.net.HttpURLConnection) url.openConnection();
                conn.setRequestMethod("POST");
                conn.setDoOutput(true);
                conn.setConnectTimeout(3000);
                conn.setReadTimeout(3000);
                conn.setRequestProperty("Content-Type", "application/json");
                byte[] data = body.getBytes("UTF-8");
                conn.setRequestProperty("Content-Length", String.valueOf(data.length));
                conn.getOutputStream().write(data);
                conn.getResponseCode();
                conn.disconnect();
            } catch (Exception ignored) {}
        }, "RegisterDevice").start();
    }

    private void checkUpdate(TextView btn, TextView statusText) {
        btn.setEnabled(false);
        btn.setText("Проверяю...");
        UpdateChecker.checkAsync(MediaServer.VERSION, new UpdateChecker.CheckCallback() {
            @Override public void onUpdateAvailable(UpdateChecker.UpdateInfo info) {
                runOnUiThread(() -> {
                    statusText.setText("Доступно v" + info.version);
                    statusText.setTextColor(Color.parseColor("#34C759"));
                    btn.setText("Скачать v" + info.version);
                    btn.setEnabled(true);
                    btn.setOnClickListener(v -> downloadUpdate(info, btn, statusText));
                });
            }
            @Override public void onUpToDate() {
                runOnUiThread(() -> {
                    statusText.setText("Актуальная версия ✓");
                    btn.setText("Проверить обновление");
                    btn.setEnabled(true);
                });
            }
            @Override public void onError(String message) {
                runOnUiThread(() -> {
                    btn.setText("Повторить");
                    btn.setEnabled(true);
                });
            }
        });
    }

    private void downloadUpdate(UpdateChecker.UpdateInfo info, TextView btn, TextView statusText) {
        btn.setEnabled(false);
        File dest = new File(Environment.getExternalStoragePublicDirectory(
                Environment.DIRECTORY_DOWNLOADS), "BrandmenAds.apk");
        UpdateChecker.downloadAsync(info.downloadUrl, dest, new UpdateChecker.DownloadCallback() {
            @Override public void onProgress(int percent) {
                runOnUiThread(() -> btn.setText(percent + "%"));
            }
            @Override public void onDone(File apkFile) {
                runOnUiThread(() -> {
                    btn.setText("Установить");
                    btn.setEnabled(true);
                    btn.setOnClickListener(v -> installApkAuto(apkFile));
                });
            }
            @Override public void onError(String message) {
                runOnUiThread(() -> {
                    btn.setText("Повторить");
                    btn.setEnabled(true);
                    btn.setOnClickListener(vv -> downloadUpdate(info, btn, statusText));
                });
            }
        });
    }

    static final String INSTALL_RESULT_ACTION = "com.brandmen.ads.INSTALL_RESULT";

    /** Установка APK (кнопка обновления). Общая реализация — в PlayerService. */
    private void installApkAuto(File apkFile) {
        PlayerService.installApk(this, apkFile);
    }

    /** Результат сессии установки. STATUS_PENDING_USER_ACTION → показать окно подтверждения. */
    private void handleInstallResult(Intent intent) {
        if (intent == null || !INSTALL_RESULT_ACTION.equals(intent.getAction())) return;
        int status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -999);
        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            Intent confirm = intent.getParcelableExtra(Intent.EXTRA_INTENT);
            if (confirm != null) {
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                try { startActivity(confirm); } catch (Exception ignored) {}
            }
        }
    }

    private void setupPlaylistUI() {
        playlistLayout = new LinearLayout(this);
        playlistLayout.setOrientation(LinearLayout.VERTICAL);
        playlistLayout.setBackgroundColor(Color.parseColor("#F2000000"));
        playlistLayout.setVisibility(View.GONE);
        playlistLayout.setPadding(50, 80, 50, 50);

        TextView title = new TextView(this);
        title.setText("Список роликов");
        title.setTextColor(Color.WHITE);
        title.setTextSize(24);
        title.setGravity(Gravity.CENTER);
        title.setPadding(0, 0, 0, 40);
        playlistLayout.addView(title);

        ScrollView scroll = new ScrollView(this);
        playlistLayout.addView(scroll, new LinearLayout.LayoutParams(-1, 0, 1));

        LinearLayout listContainer = new LinearLayout(this);
        listContainer.setOrientation(LinearLayout.VERTICAL);
        listContainer.setTag("container");
        scroll.addView(listContainer);

        TextView closeBtn = new TextView(this);
        closeBtn.setText("Закрыть");
        closeBtn.setTextColor(Color.WHITE);
        closeBtn.setTextSize(20);
        closeBtn.setGravity(Gravity.CENTER);
        closeBtn.setPadding(0, 40, 0, 40);
        closeBtn.setOnClickListener(v -> hidePlaylist());
        playlistLayout.addView(closeBtn);

        rootLayout.addView(playlistLayout, new FrameLayout.LayoutParams(-1, -1));
    }

    private void refreshPlaylistItems() {
        LinearLayout container = (LinearLayout) playlistLayout.findViewWithTag("container");
        container.removeAllViews();
        for (int i = 0; i < videoFiles.size(); i++) {
            final int index = i;
            File file = videoFiles.get(i);
            TextView item = new TextView(this);
            item.setText((i + 1) + ". " + file.getName());
            item.setTextColor(i == currentIndex ? Color.parseColor("#007AFF") : Color.WHITE);
            item.setTextSize(18);
            item.setPadding(30, 30, 30, 30);
            android.graphics.drawable.GradientDrawable border = new android.graphics.drawable.GradientDrawable();
            border.setStroke(1, Color.parseColor("#33FFFFFF"));
            item.setBackground(border);
            item.setOnClickListener(v -> { currentIndex = index; playNext(); hidePlaylist(); });
            container.addView(item);
        }
    }

    private void startSync() {
        final String ip = getServerIp();
        showSyncStatus("Связь с " + ip + "…");
        registerWithServer(ip);
        new Thread(() -> {
            try {
                URL url = new URL("http://" + ip + ":5010/api/sync/manifest");
                HttpURLConnection conn = (HttpURLConnection) url.openConnection();
                conn.setConnectTimeout(5000);

                InputStream in = new BufferedInputStream(conn.getInputStream());
                BufferedReader reader = new BufferedReader(new InputStreamReader(in));
                StringBuilder result = new StringBuilder();
                String line;
                while ((line = reader.readLine()) != null) result.append(line);

                JSONObject json = new JSONObject(result.toString());
                JSONArray files = json.getJSONArray("files");

                File dir = new File(ADS_DIR);
                if (!dir.exists()) dir.mkdirs();

                showSyncStatus("Проверяю файлы: " + files.length() + " шт.");
                int downloaded = 0, actual = 0;
                List<String> remoteNames = new ArrayList<>();
                for (int i = 0; i < files.length(); i++) {
                    JSONObject f = files.getJSONObject(i);
                    String name = f.getString("name");
                    String remoteMd5 = f.optString("md5", "");
                    long size = f.getLong("size");
                    remoteNames.add(name);

                    File local = new File(dir, name);
                    boolean needDownload = !local.exists() || local.length() != size;

                    if (!needDownload && !remoteMd5.isEmpty()) {
                        String localMd5 = calculateMD5(local);
                        if (!remoteMd5.equalsIgnoreCase(localMd5)) {
                            needDownload = true;
                        }
                    }

                    if (needDownload) {
                        final int idx = i + 1, total = files.length();
                        downloadFile(ip, name, local, size, (pct) ->
                            showSyncStatus("Загрузка " + idx + "/" + total + "\n"
                                + name + "  " + pct + "%"));
                        downloaded++;
                    } else {
                        actual++;
                    }
                }

                File[] locals = dir.listFiles();
                int removed = 0;
                if (locals != null) {
                    for (File l : locals) {
                        if (isVideo(l.getName()) && !remoteNames.contains(l.getName())) {
                            if (l.delete()) removed++;
                        }
                    }
                }

                final int dl = downloaded, ac = actual, rm = removed;
                runOnUiThread(() -> {
                    showSyncStatus("Готово ✓\nзагружено " + dl + ", актуально " + ac
                        + (rm > 0 ? ", удалено " + rm : ""));
                    syncStatusView.postDelayed(this::hideSyncStatus, 2500);
                    loadVideos(); playNext();
                });
            } catch (Exception e) {
                e.printStackTrace();
                runOnUiThread(() -> {
                    showSyncStatus("Ошибка: Mac (" + ip + ") не отвечает");
                    syncStatusView.postDelayed(this::hideSyncStatus, 4000);
                });
            }
        }).start();
    }

    private void showSyncStatus(String msg) {
        runOnUiThread(() -> {
            syncStatusView.setText(msg);
            syncStatusView.setVisibility(View.VISIBLE);
        });
    }

    private void hideSyncStatus() {
        syncStatusView.setVisibility(View.GONE);
    }

    private String calculateMD5(File file) {
        try {
            MessageDigest digest = MessageDigest.getInstance("MD5");
            InputStream is = new FileInputStream(file);
            byte[] buffer = new byte[8192];
            int read;
            while ((read = is.read(buffer)) > 0) {
                digest.update(buffer, 0, read);
            }
            is.close();
            byte[] md5sum = digest.digest();
            StringBuilder sb = new StringBuilder();
            for (byte b : md5sum) {
                sb.append(String.format("%02x", b));
            }
            return sb.toString();
        } catch (Exception e) {
            return "";
        }
    }

    interface DownloadProgress { void onPct(int pct); }

    private void downloadFile(String ip, String name, File dest, long size,
                              DownloadProgress cb) throws Exception {
        URL url = new URL("http://" + ip + ":5010/video/" + Uri.encode(name));
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        long total = size > 0 ? size : conn.getContentLength();
        File part = new File(dest.getPath() + ".part");
        InputStream is = new BufferedInputStream(conn.getInputStream());
        FileOutputStream os = new FileOutputStream(part);
        byte[] buffer = new byte[65536];
        int len; long got = 0; int lastPct = -1;
        while ((len = is.read(buffer)) != -1) {
            os.write(buffer, 0, len);
            got += len;
            if (cb != null && total > 0) {
                int pct = (int) (got * 100 / total);
                if (pct != lastPct) { lastPct = pct; cb.onPct(pct); }
            }
        }
        os.close(); is.close();
        if (dest.exists()) dest.delete();
        part.renameTo(dest); // атомарная замена — недокачанный файл не подменит рабочий
    }

    private TextView createStyledButton(String text) {
        TextView tv = new TextView(this); tv.setText(text); tv.setTextSize(40); tv.setTextColor(Color.WHITE);
        tv.setGravity(Gravity.CENTER); tv.setPadding(40, 20, 40, 20); return tv;
    }

    private void toggleControls() {
        if (isPlaylistVisible) return;
        isControlsVisible = !isControlsVisible;
        controlsLayout.setVisibility(isControlsVisible ? View.VISIBLE : View.GONE);
        if (isControlsVisible) resetHideTimer();
    }

    private void showPlaylist() {
        isPlaylistVisible = true; isControlsVisible = false;
        controlsLayout.setVisibility(View.GONE); refreshPlaylistItems();
        playlistLayout.setVisibility(View.VISIBLE);
        hideHandler.removeCallbacksAndMessages(null);
    }

    private void hidePlaylist() {
        isPlaylistVisible = false; playlistLayout.setVisibility(View.GONE); toggleControls();
    }

    private void resetHideTimer() {
        hideHandler.removeCallbacksAndMessages(null);
        hideHandler.postDelayed(() -> { if (!isPlaylistVisible) { isControlsVisible = false; controlsLayout.setVisibility(View.GONE); } }, 5000);
    }

    private void startProgressUpdater() {
        final Handler handler = new Handler();
        handler.post(new Runnable() {
            @Override public void run() {
                try {
                    if (videoView.getDuration() > 0) {
                        int cur = videoView.getCurrentPosition(); int dur = videoView.getDuration();
                        progressBar.setMax(dur); progressBar.setProgress(cur);
                        timeText.setText(formatTime(cur) + " / " + formatTime(dur));
                        playPauseBtn.setText(videoView.isPlaying() ? "⏸" : "▶");
                    }
                } catch (Exception e) {}
                handler.postDelayed(this, 500);
            }
        });
    }

    private String formatTime(int ms) {
        int sec = ms / 1000; int min = sec / 60; sec = sec % 60;
        return String.format(Locale.getDefault(), "%02d:%02d", min, sec);
    }

    private void checkPermissions() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            if (!Environment.isExternalStorageManager()) {
                Intent intent = new Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION);
                intent.setData(Uri.parse("package:" + getPackageName()));
                startActivityForResult(intent, 100);
            } else { startPlayback(); }
        } else { startPlayback(); }
    }

    @Override protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode == 100) startPlayback();
    }

    @Override protected void onDestroy() {
        if (wakeLock != null && wakeLock.isHeld()) {
            try { wakeLock.release(); } catch (Exception ignored) {}
        }
        if (peek() == this) sRef = null;
        // HTTP-сервер и Wi-Fi-лок не трогаем — ими владеет PlayerService,
        // который должен пережить закрытие Activity.
        super.onDestroy();
    }

    // ---- MediaServer.ControlCallback ----

    @Override public void onWake() {
        android.os.PowerManager pm = (android.os.PowerManager) getSystemService(POWER_SERVICE);
        if (wakeLock != null && wakeLock.isHeld()) {
            try { wakeLock.release(); } catch (Exception ignored) {}
        }
        wakeLock = pm.newWakeLock(
            android.os.PowerManager.FULL_WAKE_LOCK |
            android.os.PowerManager.ACQUIRE_CAUSES_WAKEUP |
            android.os.PowerManager.ON_AFTER_RELEASE,
            "Brandmen::RemoteWake");
        wakeLock.acquire(10_000L);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.KeyguardManager km = (android.app.KeyguardManager) getSystemService(KEYGUARD_SERVICE);
            km.requestDismissKeyguard(this, null);
        }
    }

    @Override public void onSleep() {
        if (dpm != null && dpm.isAdminActive(adminComponent)) {
            dpm.lockNow();
        } else {
            // Device admin not active — prompt user to activate it
            Intent intent = new Intent(android.app.admin.DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN);
            intent.putExtra(android.app.admin.DevicePolicyManager.EXTRA_DEVICE_ADMIN, adminComponent);
            intent.putExtra(android.app.admin.DevicePolicyManager.EXTRA_ADD_EXPLANATION,
                "Нужно для удалённого выключения экрана");
            startActivity(intent);
        }
    }

    @Override public void onVolume(int level) {
        int max = audioManager.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC);
        audioManager.setStreamVolume(android.media.AudioManager.STREAM_MUSIC,
            Math.max(0, Math.min(level, max)), 0);
    }

    @Override public void onBrightness(int level) {
        WindowManager.LayoutParams lp = getWindow().getAttributes();
        lp.screenBrightness = Math.max(0.01f, Math.min(level / 255.0f, 1.0f));
        getWindow().setAttributes(lp);
    }

    @Override public void onLaunch() {
        loadVideos();
        currentIndex = 0;
        playNext();
    }

    @Override public void onRestart() {
        currentIndex = 0;
        playNext();
    }

    @Override public void onInstallApk(File apkFile) {
        installApkAuto(apkFile);
    }

    @Override public int getCurrentIndex() {
        return videoFiles.isEmpty() ? -1 : currentIndex;
    }

    @Override public int getPlaylistCount() {
        return videoFiles.size();
    }

    @Override public String getCurrentName() {
        if (currentIndex < 0 || currentIndex >= videoFiles.size()) return "";
        return videoFiles.get(currentIndex).getName();
    }

    @Override public boolean isPlaying() {
        try { return videoView.isPlaying(); } catch (Exception e) { return false; }
    }

    @Override public int getVolume() {
        return audioManager.getStreamVolume(android.media.AudioManager.STREAM_MUSIC);
    }

    @Override public int getVolumeMax() {
        return audioManager.getStreamMaxVolume(android.media.AudioManager.STREAM_MUSIC);
    }

    @Override public int getBrightness() {
        float b = getWindow().getAttributes().screenBrightness;
        if (b < 0) {
            try {
                return Settings.System.getInt(getContentResolver(),
                    Settings.System.SCREEN_BRIGHTNESS, 128);
            } catch (Exception e) { return 128; }
        }
        return (int) (b * 255);
    }

    private void startPlayback() { loadVideos(); playNext(); resetHideTimer(); }

    private void loadVideos() {
        videoFiles.clear();
        File playlist = new File(PLAYLIST_FILE);
        if (playlist.exists()) {
            try (BufferedReader br = new BufferedReader(new FileReader(playlist))) {
                String line;
                while ((line = br.readLine()) != null) {
                    if (line.startsWith("#") || line.trim().isEmpty()) continue;
                    File f = new File(line.trim());
                    if (!f.isAbsolute()) f = new File(ADS_DIR, line.trim());
                    if (!f.exists()) f = new File(ADS_DIR, f.getName());
                    if (f.exists() && isVideo(f.getName())) { if (!videoFiles.contains(f)) videoFiles.add(f); }
                }
            } catch (IOException e) {}
        }
        if (videoFiles.isEmpty()) {
            File dir = new File(ADS_DIR);
            if (dir.exists() && dir.isDirectory()) {
                File[] files = dir.listFiles();
                if (files != null) {
                    for (File f : files) { if (isVideo(f.getName())) videoFiles.add(f); }
                }
            }
            videoFiles.sort((f1, f2) -> f1.getName().compareTo(f2.getName()));
        }
    }

    private boolean isVideo(String name) {
        String n = name.toLowerCase();
        return n.endsWith(".mp4") || n.endsWith(".mkv") || n.endsWith(".mov")
                || n.endsWith(".avi") || n.endsWith(".webm");
    }

    private void playNext() {
        if (videoFiles.isEmpty()) {
            loadVideos();
            if (videoFiles.isEmpty()) {
                // Нет роликов — показываем заглушку вместо чёрного экрана и
                // продолжаем периодически проверять.
                if (recoveryView != null) recoveryView.setVisibility(View.VISIBLE);
                videoView.postDelayed(this::playNext, 5000);
                return;
            }
        }
        if (recoveryView != null) recoveryView.setVisibility(View.GONE);
        if (currentIndex >= videoFiles.size()) currentIndex = 0;
        if (currentIndex < 0) currentIndex = 0;
        videoView.setVideoPath(videoFiles.get(currentIndex).getAbsolutePath());
        videoView.start();
        playPauseBtn.setText("⏸");
        userPaused = false;
    }
}
