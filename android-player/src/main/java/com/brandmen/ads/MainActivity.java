package com.brandmen.ads;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.SharedPreferences;
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

public class MainActivity extends Activity {
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

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        audioManager = (android.media.AudioManager) getSystemService(AUDIO_SERVICE);
        prefs = getSharedPreferences("BrandmenPrefs", MODE_PRIVATE);
        
        android.net.wifi.WifiManager wifi = (android.net.wifi.WifiManager) getSystemService(Context.WIFI_SERVICE);
        multicastLock = wifi.createMulticastLock("brandmen_lock");
        multicastLock.setReferenceCounted(true);

        nsdManager = (NsdManager) getSystemService(Context.NSD_SERVICE);
        initializeDiscoveryListener();

        rootLayout = new FrameLayout(this);
        rootLayout.setBackgroundColor(Color.BLACK);
        setContentView(rootLayout);

        videoView = new VideoView(this);
        rootLayout.addView(videoView, new FrameLayout.LayoutParams(-1, -1, Gravity.CENTER));

        setupUI();
        setupPlaylistUI();
        
        videoView.setOnCompletionListener(mp -> { currentIndex++; playNext(); });
        videoView.setOnErrorListener((mp, what, extra) -> { currentIndex++; playNext(); return true; });
        rootLayout.setOnClickListener(v -> { if (isPlaylistVisible) hidePlaylist(); else toggleControls(); });

        checkPermissions();
        startProgressUpdater();
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
            if (videoView.isPlaying()) { videoView.pause(); playPauseBtn.setText("▶"); } 
            else { videoView.start(); playPauseBtn.setText("⏸"); }
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

    private void showSettingsDialog() {
        final EditText input = new EditText(this);
        input.setText(getServerIp());
        input.setHint("192.168.1.xxx");
        
        new AlertDialog.Builder(this)
            .setTitle("IP адрес Mac")
            .setMessage("Введите IP вашего Mac для обновления видео:")
            .setView(input)
            .setPositiveButton("Сохранить", (dialog, which) -> {
                String ip = input.getText().toString().trim();
                prefs.edit().putString("server_ip", ip).apply();
                Toast.makeText(this, "IP сохранен: " + ip, Toast.LENGTH_SHORT).show();
            })
            .setNegativeButton("Отмена", null)
            .show();
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
        Toast.makeText(this, "Связь с " + ip + "...", Toast.LENGTH_SHORT).show();
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
                
                List<String> remoteNames = new ArrayList<>();
                for (int i = 0; i < files.length(); i++) {
                    JSONObject f = files.getJSONObject(i);
                    String name = f.getString("name");
                    String remoteMd5 = f.optString("md5", "");
                    remoteNames.add(name);
                    
                    File local = new File(dir, name);
                    boolean needDownload = !local.exists() || local.length() != f.getLong("size");
                    
                    if (!needDownload && !remoteMd5.isEmpty()) {
                        String localMd5 = calculateMD5(local);
                        if (!remoteMd5.equalsIgnoreCase(localMd5)) {
                            needDownload = true;
                        }
                    }

                    if (needDownload) {
                        downloadFile(ip, name, local);
                    }
                }
                
                File[] locals = dir.listFiles();
                if (locals != null) {
                    for (File l : locals) {
                        if (isVideo(l.getName()) && !remoteNames.contains(l.getName())) l.delete();
                    }
                }
                
                runOnUiThread(() -> {
                    Toast.makeText(this, "Обновлено!", Toast.LENGTH_SHORT).show();
                    loadVideos(); playNext();
                });
            } catch (Exception e) {
                e.printStackTrace();
                runOnUiThread(() -> Toast.makeText(this, "Mac (" + ip + ") не отвечает", Toast.LENGTH_LONG).show());
            }
        }).start();
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

    private void downloadFile(String ip, String name, File dest) throws Exception {
        URL url = new URL("http://" + ip + ":5010/video/" + Uri.encode(name));
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        InputStream is = conn.getInputStream();
        FileOutputStream os = new FileOutputStream(dest);
        byte[] buffer = new byte[8192];
        int len;
        while ((len = is.read(buffer)) != -1) {
            os.write(buffer, 0, len);
        }
        os.close(); is.close();
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
        return n.endsWith(".mp4") || n.endsWith(".mkv") || n.endsWith(".mov") || n.endsWith(".avi");
    }

    private void playNext() {
        if (videoFiles.isEmpty()) {
            loadVideos();
            if (videoFiles.isEmpty()) { videoView.postDelayed(this::playNext, 5000); return; }
        }
        if (currentIndex >= videoFiles.size()) currentIndex = 0;
        if (currentIndex < 0) currentIndex = 0;
        videoView.setVideoPath(videoFiles.get(currentIndex).getAbsolutePath());
        videoView.start();
        playPauseBtn.setText("⏸");
    }
}
