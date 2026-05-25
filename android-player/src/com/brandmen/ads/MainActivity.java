package com.brandmen.ads;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.animation.AlphaAnimation;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.SeekBar;
import android.widget.TextView;
import android.widget.Toast;
import android.widget.VideoView;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;

public class MainActivity extends Activity {

    // ---- Цветовая палитра ----
    private static final int BG_PRIMARY     = 0xFF000000;
    private static final int CARD_BG        = 0xCC1C1C1E;
    private static final int CARD_BG_SOLID  = 0xFF1C1C1E;
    private static final int ACCENT_BLUE    = 0xFF0A84FF;
    private static final int ACCENT_GREEN   = 0xFF30D158;
    private static final int ACCENT_RED     = 0xFFFF453A;
    private static final int TEXT_PRIMARY   = 0xFFFFFFFF;
    private static final int TEXT_SECONDARY = 0x99FFFFFF;
    private static final int TEXT_TERTIARY  = 0x55FFFFFF;
    private static final int DIVIDER        = 0x22FFFFFF;

    // ---- Константы ----
    private static final String PREFS_NAME = "BrandmenPrefs";
    private static final String KEY_SERVER_IP = "server_ip";
    private static final String KEY_MEDIA_FOLDER = "media_folder";
    private static final String DEFAULT_MEDIA_FOLDER = "/sdcard/Movies/ads";
    private static final String DEFAULT_SERVER_IP = "192.168.1.107";
    private static final String PLAYLIST_NAME = "playlist.m3u";

    // ---- Состояние ----
    private SharedPreferences prefs;
    private AudioManager audioManager;
    private MediaServer mediaServer;
    private VideoView videoView;
    private FrameLayout rootLayout;
    private LinearLayout controlsPanel;
    private LinearLayout playlistPanel;
    private TextView playPauseBtn;
    private TextView trackInfoText;
    private TextView timeText;
    private ProgressBar seekBar;
    private SeekBar volumeBar;

    private final List<File> videoFiles = new ArrayList<>();
    private int currentIndex = 0;
    private boolean controlsVisible = true;
    private boolean playlistVisible = false;
    private final Handler hideHandler = new Handler(Looper.getMainLooper());
    private final Handler uiHandler = new Handler(Looper.getMainLooper());

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        audioManager = (AudioManager) getSystemService(AUDIO_SERVICE);
        prefs = getSharedPreferences(PREFS_NAME, 0);

        rootLayout = new FrameLayout(this);
        rootLayout.setBackgroundColor(BG_PRIMARY);
        setContentView(rootLayout);

        // VideoView во всё пространство
        videoView = new VideoView(this);
        rootLayout.addView(videoView, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT, Gravity.CENTER));

        buildControlsPanel();
        buildPlaylistPanel();

        videoView.setOnCompletionListener(new MediaPlayer.OnCompletionListener() {
            @Override public void onCompletion(MediaPlayer mp) { next(); }
        });
        videoView.setOnErrorListener(new MediaPlayer.OnErrorListener() {
            @Override public boolean onError(MediaPlayer mp, int what, int extra) {
                String failedName = (currentIndex < videoFiles.size())
                        ? videoFiles.get(currentIndex).getName() : "?";
                runOnUiThread(() -> Toast.makeText(MainActivity.this,
                        "Не удалось воспроизвести: " + failedName, Toast.LENGTH_SHORT).show());
                uiHandler.postDelayed(() -> next(), 800);
                return true;
            }
        });
        rootLayout.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) {
                if (playlistVisible) hidePlaylist();
                else toggleControls();
            }
        });

        startMediaServer();
        checkPermissions();
        startProgressUpdater();
    }

    // ---- UI: панель управления внизу ----
    private void buildControlsPanel() {
        int dp = dp(1);

        controlsPanel = new LinearLayout(this);
        controlsPanel.setOrientation(LinearLayout.VERTICAL);
        controlsPanel.setPadding(20 * dp, 16 * dp, 20 * dp, 18 * dp);

        GradientDrawable bg = new GradientDrawable();
        bg.setColor(CARD_BG);
        bg.setCornerRadius(28 * dp);
        controlsPanel.setBackground(bg);

        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(
                900 * dp / 2, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.gravity = Gravity.BOTTOM | Gravity.CENTER_HORIZONTAL;
        lp.bottomMargin = 30 * dp;
        rootLayout.addView(controlsPanel, lp);

        // Верхняя строка: название трека + иконки справа
        LinearLayout topRow = new LinearLayout(this);
        topRow.setOrientation(LinearLayout.HORIZONTAL);
        topRow.setGravity(Gravity.CENTER_VERTICAL);
        controlsPanel.addView(topRow);

        LinearLayout textCol = new LinearLayout(this);
        textCol.setOrientation(LinearLayout.VERTICAL);

        trackInfoText = new TextView(this);
        trackInfoText.setText("Brandmen Ads · v" + MediaServer.VERSION);
        trackInfoText.setTextColor(TEXT_PRIMARY);
        trackInfoText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        trackInfoText.setTypeface(Typeface.DEFAULT_BOLD);
        trackInfoText.setMaxLines(1);
        trackInfoText.setEllipsize(android.text.TextUtils.TruncateAt.END);
        textCol.addView(trackInfoText);

        timeText = new TextView(this);
        timeText.setText("00:00 / 00:00");
        timeText.setTextColor(TEXT_TERTIARY);
        timeText.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        textCol.addView(timeText);

        topRow.addView(textCol, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        topRow.addView(iconBtn("↻", ACCENT_GREEN, new View.OnClickListener() {
            @Override public void onClick(View v) { startSync(); }
        }));
        topRow.addView(iconBtn("≡", TEXT_PRIMARY, new View.OnClickListener() {
            @Override public void onClick(View v) { showPlaylist(); }
        }));
        topRow.addView(iconBtn("⚙", TEXT_PRIMARY, new View.OnClickListener() {
            @Override public void onClick(View v) { showSettings(); }
        }));
        topRow.addView(iconBtn("✕", ACCENT_RED, new View.OnClickListener() {
            @Override public void onClick(View v) { finish(); }
        }));

        // Прогрессбар
        seekBar = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        seekBar.getProgressDrawable().setColorFilter(ACCENT_BLUE, android.graphics.PorterDuff.Mode.SRC_IN);
        LinearLayout.LayoutParams sbLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 4 * dp);
        sbLp.topMargin = 12 * dp;
        controlsPanel.addView(seekBar, sbLp);

        // Кнопки управления
        LinearLayout buttonsRow = new LinearLayout(this);
        buttonsRow.setOrientation(LinearLayout.HORIZONTAL);
        buttonsRow.setGravity(Gravity.CENTER);
        LinearLayout.LayoutParams brLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        brLp.topMargin = 14 * dp;
        controlsPanel.addView(buttonsRow, brLp);

        TextView prevBtn = circleBtn("⏮", 22, new View.OnClickListener() {
            @Override public void onClick(View v) { prev(); }
        });
        buttonsRow.addView(prevBtn);

        space(buttonsRow, 16 * dp);

        playPauseBtn = circleBtn("▶", 32, new View.OnClickListener() {
            @Override public void onClick(View v) { togglePlay(); }
        });
        ((LinearLayout.LayoutParams) playPauseBtn.getLayoutParams()).width = 64 * dp;
        ((LinearLayout.LayoutParams) playPauseBtn.getLayoutParams()).height = 64 * dp;
        GradientDrawable pp = new GradientDrawable();
        pp.setShape(GradientDrawable.OVAL);
        pp.setColor(ACCENT_BLUE);
        playPauseBtn.setBackground(pp);
        buttonsRow.addView(playPauseBtn);

        space(buttonsRow, 16 * dp);

        TextView nextBtn = circleBtn("⏭", 22, new View.OnClickListener() {
            @Override public void onClick(View v) { next(); }
        });
        buttonsRow.addView(nextBtn);

        // Громкость
        LinearLayout volRow = new LinearLayout(this);
        volRow.setOrientation(LinearLayout.HORIZONTAL);
        volRow.setGravity(Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams vrLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        vrLp.topMargin = 16 * dp;
        controlsPanel.addView(volRow, vrLp);

        TextView volLow = new TextView(this);
        volLow.setText("🔈");
        volLow.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        volRow.addView(volLow);

        volumeBar = new SeekBar(this);
        volumeBar.getProgressDrawable().setColorFilter(ACCENT_BLUE, android.graphics.PorterDuff.Mode.SRC_IN);
        volumeBar.getThumb().setColorFilter(ACCENT_BLUE, android.graphics.PorterDuff.Mode.SRC_IN);
        volumeBar.setMax(audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC));
        volumeBar.setProgress(audioManager.getStreamVolume(AudioManager.STREAM_MUSIC));
        volumeBar.setOnSeekBarChangeListener(new SeekBar.OnSeekBarChangeListener() {
            @Override public void onProgressChanged(SeekBar s, int p, boolean u) {
                if (u) audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, p, 0);
                resetHideTimer();
            }
            @Override public void onStartTrackingTouch(SeekBar s) {}
            @Override public void onStopTrackingTouch(SeekBar s) {}
        });
        LinearLayout.LayoutParams vbLp = new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
        vbLp.leftMargin = 12 * dp;
        vbLp.rightMargin = 12 * dp;
        volRow.addView(volumeBar, vbLp);

        TextView volHigh = new TextView(this);
        volHigh.setText("🔊");
        volHigh.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        volRow.addView(volHigh);
    }

    private void space(LinearLayout parent, int width) {
        View s = new View(this);
        parent.addView(s, new LinearLayout.LayoutParams(width, 1));
    }

    private TextView iconBtn(String text, int color, View.OnClickListener onClick) {
        int dp = dp(1);
        TextView b = new TextView(this);
        b.setText(text);
        b.setTextColor(color);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, 20);
        b.setGravity(Gravity.CENTER);
        b.setPadding(10 * dp, 6 * dp, 10 * dp, 6 * dp);
        b.setOnClickListener(onClick);
        return b;
    }

    private TextView circleBtn(String text, int textSize, View.OnClickListener onClick) {
        int dp = dp(1);
        TextView b = new TextView(this);
        b.setText(text);
        b.setTextColor(TEXT_PRIMARY);
        b.setTextSize(TypedValue.COMPLEX_UNIT_SP, textSize);
        b.setGravity(Gravity.CENTER);
        b.setOnClickListener(onClick);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(48 * dp, 48 * dp);
        b.setLayoutParams(lp);

        GradientDrawable bg = new GradientDrawable();
        bg.setShape(GradientDrawable.OVAL);
        bg.setColor(0x33FFFFFF);
        b.setBackground(bg);
        return b;
    }

    // ---- Плейлист ----
    private void buildPlaylistPanel() {
        int dp = dp(1);

        playlistPanel = new LinearLayout(this);
        playlistPanel.setOrientation(LinearLayout.VERTICAL);
        playlistPanel.setBackgroundColor(0xF2000000);
        playlistPanel.setVisibility(View.GONE);
        playlistPanel.setPadding(40 * dp, 32 * dp, 40 * dp, 24 * dp);

        // Заголовок с кнопкой закрытия
        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(Gravity.CENTER_VERTICAL);
        playlistPanel.addView(header);

        TextView title = new TextView(this);
        title.setText("Плейлист");
        title.setTextColor(TEXT_PRIMARY);
        title.setTextSize(TypedValue.COMPLEX_UNIT_SP, 28);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        header.addView(title, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        TextView closeBtn = new TextView(this);
        closeBtn.setText("✕");
        closeBtn.setTextColor(TEXT_PRIMARY);
        closeBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        closeBtn.setPadding(16 * dp, 8 * dp, 16 * dp, 8 * dp);
        closeBtn.setOnClickListener(new View.OnClickListener() {
            @Override public void onClick(View v) { hidePlaylist(); }
        });
        header.addView(closeBtn);

        ScrollView scroll = new ScrollView(this);
        LinearLayout.LayoutParams sLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f);
        sLp.topMargin = 20 * dp;
        playlistPanel.addView(scroll, sLp);

        LinearLayout listContainer = new LinearLayout(this);
        listContainer.setOrientation(LinearLayout.VERTICAL);
        listContainer.setTag("container");
        scroll.addView(listContainer);

        rootLayout.addView(playlistPanel, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
    }

    private void refreshPlaylistItems() {
        int dp = dp(1);
        LinearLayout container = (LinearLayout) playlistPanel.findViewWithTag("container");
        container.removeAllViews();

        if (videoFiles.isEmpty()) {
            TextView empty = new TextView(this);
            empty.setText("Нет видеофайлов\n\nНажмите ↻ для синхронизации с Mac");
            empty.setTextColor(TEXT_SECONDARY);
            empty.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
            empty.setGravity(Gravity.CENTER);
            empty.setPadding(0, 60 * dp, 0, 0);
            container.addView(empty);
            return;
        }

        for (int i = 0; i < videoFiles.size(); i++) {
            final int index = i;
            final File file = videoFiles.get(i);
            boolean isCurrent = (i == currentIndex);

            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(20 * dp, 18 * dp, 20 * dp, 18 * dp);

            GradientDrawable bg = new GradientDrawable();
            bg.setColor(isCurrent ? 0x33007AFF : 0x14FFFFFF);
            bg.setCornerRadius(12 * dp);
            row.setBackground(bg);

            // Номер
            TextView num = new TextView(this);
            num.setText(String.valueOf(i + 1));
            num.setTextColor(isCurrent ? ACCENT_BLUE : TEXT_TERTIARY);
            num.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
            num.setTypeface(Typeface.DEFAULT_BOLD);
            num.setGravity(Gravity.CENTER);
            LinearLayout.LayoutParams numLp = new LinearLayout.LayoutParams(36 * dp,
                    ViewGroup.LayoutParams.WRAP_CONTENT);
            row.addView(num, numLp);

            // Название
            TextView name = new TextView(this);
            name.setText(file.getName());
            name.setTextColor(isCurrent ? ACCENT_BLUE : TEXT_PRIMARY);
            name.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
            if (isCurrent) name.setTypeface(Typeface.DEFAULT_BOLD);
            name.setMaxLines(1);
            name.setEllipsize(android.text.TextUtils.TruncateAt.MIDDLE);
            LinearLayout.LayoutParams nameLp = new LinearLayout.LayoutParams(0,
                    ViewGroup.LayoutParams.WRAP_CONTENT, 1f);
            nameLp.leftMargin = 16 * dp;
            row.addView(name, nameLp);

            // Иконка воспроизведения для текущего
            if (isCurrent) {
                TextView playIcon = new TextView(this);
                playIcon.setText("▶");
                playIcon.setTextColor(ACCENT_BLUE);
                playIcon.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
                row.addView(playIcon);
            }

            row.setOnClickListener(new View.OnClickListener() {
                @Override public void onClick(View v) {
                    currentIndex = index;
                    play();
                    hidePlaylist();
                }
            });

            LinearLayout.LayoutParams rLp = new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
            rLp.bottomMargin = 8 * dp;
            container.addView(row, rLp);
        }
    }

    // ---- Настройки ----
    private DiscoveryListener activeDiscovery;

    private void showSettings() {
        int dp = dp(1);
        LinearLayout content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(28 * dp, 20 * dp, 28 * dp, 8 * dp);

        // Заголовок IP
        TextView ipLabel = new TextView(this);
        ipLabel.setText("IP адрес компьютера");
        ipLabel.setTextColor(TEXT_PRIMARY);
        ipLabel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        ipLabel.setTypeface(Typeface.DEFAULT_BOLD);
        content.addView(ipLabel);

        // Строка: поле ввода + кнопка "Найти"
        LinearLayout ipRow = new LinearLayout(this);
        ipRow.setOrientation(LinearLayout.HORIZONTAL);
        ipRow.setGravity(android.view.Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams ipRowLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        ipRowLp.topMargin = 8 * dp;
        content.addView(ipRow, ipRowLp);

        final EditText ipInput = new EditText(this);
        ipInput.setText(prefs.getString(KEY_SERVER_IP, DEFAULT_SERVER_IP));
        ipInput.setHint("192.168.1.xxx");
        ipInput.setInputType(InputType.TYPE_CLASS_TEXT);
        ipInput.setTextColor(TEXT_PRIMARY);
        ipInput.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        ipRow.addView(ipInput, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        // Статус поиска
        final TextView searchStatus = new TextView(this);
        searchStatus.setText("");
        searchStatus.setTextColor(ACCENT_BLUE);
        searchStatus.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        LinearLayout.LayoutParams ssLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        ssLp.topMargin = 4 * dp;
        ssLp.bottomMargin = 16 * dp;
        content.addView(searchStatus, ssLp);

        // Кнопка "Найти автоматически"
        TextView findBtn = new TextView(this);
        findBtn.setText("🔍 Найти");
        findBtn.setTextColor(ACCENT_BLUE);
        findBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        findBtn.setPadding(12 * dp, 6 * dp, 4 * dp, 6 * dp);
        findBtn.setOnClickListener(v -> startDiscovery(ipInput, findBtn, searchStatus));
        ipRow.addView(findBtn);

        // Папка
        TextView folderLabel = new TextView(this);
        folderLabel.setText("Папка с видео на планшете");
        folderLabel.setTextColor(TEXT_PRIMARY);
        folderLabel.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        folderLabel.setTypeface(Typeface.DEFAULT_BOLD);
        content.addView(folderLabel);

        final EditText folderInput = new EditText(this);
        folderInput.setText(getMediaFolder());
        folderInput.setHint(DEFAULT_MEDIA_FOLDER);
        folderInput.setInputType(InputType.TYPE_CLASS_TEXT);
        folderInput.setTextColor(TEXT_PRIMARY);
        folderInput.setTextSize(TypedValue.COMPLEX_UNIT_SP, 16);
        LinearLayout.LayoutParams fLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        fLp.topMargin = 8 * dp;
        content.addView(folderInput, fLp);

        TextView hint = new TextView(this);
        hint.setText("По умолчанию: " + DEFAULT_MEDIA_FOLDER + "\nВидео в этой папке проигрываются по порядку из playlist.m3u");
        hint.setTextColor(TEXT_TERTIARY);
        hint.setTextSize(TypedValue.COMPLEX_UNIT_SP, 11);
        LinearLayout.LayoutParams hLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        hLp.topMargin = 6 * dp;
        hLp.bottomMargin = 16 * dp;
        content.addView(hint, hLp);

        // Разделитель
        View divider = new View(this);
        divider.setBackgroundColor(DIVIDER);
        content.addView(divider, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 1));

        // Строка обновления
        LinearLayout updateRow = new LinearLayout(this);
        updateRow.setOrientation(LinearLayout.HORIZONTAL);
        updateRow.setGravity(android.view.Gravity.CENTER_VERTICAL);
        LinearLayout.LayoutParams urLp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        urLp.topMargin = 14 * dp;
        content.addView(updateRow, urLp);

        final TextView updateStatus = new TextView(this);
        updateStatus.setText("v" + MediaServer.VERSION);
        updateStatus.setTextColor(TEXT_SECONDARY);
        updateStatus.setTextSize(TypedValue.COMPLEX_UNIT_SP, 12);
        updateRow.addView(updateStatus, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        final TextView updateBtn = new TextView(this);
        updateBtn.setText("Проверить обновление");
        updateBtn.setTextColor(ACCENT_BLUE);
        updateBtn.setTextSize(TypedValue.COMPLEX_UNIT_SP, 13);
        updateBtn.setPadding(0, 6 * dp, 0, 6 * dp);
        updateBtn.setOnClickListener(v -> checkUpdate(updateBtn, updateStatus));
        updateRow.addView(updateBtn);

        new AlertDialog.Builder(this)
                .setTitle("Настройки · v" + MediaServer.VERSION)
                .setView(content)
                .setPositiveButton("Сохранить", (dialog, which) -> {
                    if (activeDiscovery != null) { activeDiscovery.cancel(); activeDiscovery = null; }
                    String ip = ipInput.getText().toString().trim();
                    String folder = folderInput.getText().toString().trim();
                    if (folder.isEmpty()) folder = DEFAULT_MEDIA_FOLDER;
                    if (ip.contains(":")) ip = ip.substring(0, ip.indexOf(':'));
                    prefs.edit()
                            .putString(KEY_SERVER_IP, ip)
                            .putString(KEY_MEDIA_FOLDER, folder)
                            .apply();
                    Toast.makeText(this, "Сохранено", Toast.LENGTH_SHORT).show();
                    loadVideos();
                    refreshPlaylistItems();
                })
                .setNegativeButton("Отмена", (dialog, which) -> {
                    if (activeDiscovery != null) { activeDiscovery.cancel(); activeDiscovery = null; }
                })
                .show();
    }

    private void startDiscovery(EditText ipInput, TextView findBtn, TextView statusText) {
        if (activeDiscovery != null) activeDiscovery.cancel();
        activeDiscovery = new DiscoveryListener();
        findBtn.setText("⏳");
        findBtn.setEnabled(false);
        statusText.setText("Ищу компьютер в сети...");
        activeDiscovery.findAsync(new DiscoveryListener.Callback() {
            @Override public void onFound(String ip) {
                runOnUiThread(() -> {
                    ipInput.setText(ip);
                    findBtn.setText("✓");
                    findBtn.setTextColor(ACCENT_GREEN);
                    statusText.setText("Найден: " + ip);
                    activeDiscovery = null;
                });
            }
            @Override public void onTimeout() {
                runOnUiThread(() -> {
                    findBtn.setText("🔍 Найти");
                    findBtn.setEnabled(true);
                    findBtn.setTextColor(ACCENT_BLUE);
                    statusText.setText("Не найден. Убедитесь, что Brandmen Control запущен.");
                    activeDiscovery = null;
                });
            }
        });
    }

    private void checkUpdate(TextView btn, TextView statusText) {
        btn.setEnabled(false);
        btn.setText("Проверяю...");
        statusText.setText("v" + MediaServer.VERSION);
        UpdateChecker.checkAsync(MediaServer.VERSION, new UpdateChecker.CheckCallback() {
            @Override public void onUpdateAvailable(UpdateChecker.UpdateInfo info) {
                runOnUiThread(() -> {
                    statusText.setText("Доступно v" + info.version);
                    statusText.setTextColor(ACCENT_GREEN);
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
                    statusText.setText("Ошибка проверки");
                    btn.setText("Повторить");
                    btn.setEnabled(true);
                });
            }
        });
    }

    private void downloadUpdate(UpdateChecker.UpdateInfo info, TextView btn, TextView statusText) {
        btn.setEnabled(false);
        btn.setText("Скачиваю...");
        File dest = new File(android.os.Environment.getExternalStoragePublicDirectory(
                android.os.Environment.DIRECTORY_DOWNLOADS), "BrandmenAds.apk");
        UpdateChecker.downloadAsync(info.downloadUrl, dest, new UpdateChecker.DownloadCallback() {
            @Override public void onProgress(int percent) {
                runOnUiThread(() -> btn.setText(percent + "%"));
            }
            @Override public void onDone(File apkFile) {
                runOnUiThread(() -> {
                    statusText.setText("Скачано → " + apkFile.getPath());
                    btn.setText("Установить");
                    btn.setEnabled(true);
                    btn.setOnClickListener(v -> installApk(apkFile));
                });
            }
            @Override public void onError(String message) {
                runOnUiThread(() -> {
                    statusText.setText("Ошибка скачивания");
                    btn.setText("Повторить");
                    btn.setEnabled(true);
                    btn.setOnClickListener(vv -> downloadUpdate(info, btn, statusText));
                });
            }
        });
    }

    private void installApk(File apkFile) {
        try {
            android.content.Intent intent = new android.content.Intent(
                    android.content.Intent.ACTION_VIEW);
            intent.setDataAndType(android.net.Uri.fromFile(apkFile),
                    "application/vnd.android.package-archive");
            intent.setFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK);
            startActivity(intent);
        } catch (Exception e) {
            Toast.makeText(this,
                    "Откройте файл вручную: " + apkFile.getPath(), Toast.LENGTH_LONG).show();
        }
    }

    // ---- Воспроизведение ----
    private void togglePlay() {
        if (videoView.isPlaying()) {
            videoView.pause();
            playPauseBtn.setText("▶");
        } else {
            videoView.start();
            playPauseBtn.setText("⏸");
        }
        resetHideTimer();
    }

    private void prev() {
        currentIndex--;
        if (currentIndex < 0) currentIndex = Math.max(0, videoFiles.size() - 1);
        play();
    }

    private void next() {
        currentIndex++;
        play();
    }

    private void play() {
        if (videoFiles.isEmpty()) {
            loadVideos();
            if (videoFiles.isEmpty()) {
                trackInfoText.setText("Нет видеофайлов");
                videoView.postDelayed(this::play, 5000);
                return;
            }
        }
        if (currentIndex >= videoFiles.size()) currentIndex = 0;
        if (currentIndex < 0) currentIndex = 0;
        File f = videoFiles.get(currentIndex);
        trackInfoText.setText((currentIndex + 1) + "/" + videoFiles.size() + " · " + f.getName());
        videoView.stopPlayback();
        videoView.setVideoURI(Uri.fromFile(f));
        videoView.setOnPreparedListener(mp -> {
            mp.setLooping(false);
            videoView.start();
            playPauseBtn.setText("⏸");
        });
        videoView.requestFocus();
        if (playlistVisible) refreshPlaylistItems();
    }

    // ---- Управление UI ----
    private void toggleControls() {
        if (playlistVisible) return;
        controlsVisible = !controlsVisible;
        fade(controlsPanel, controlsVisible);
        if (controlsVisible) resetHideTimer();
    }

    private void fade(View v, boolean show) {
        v.setVisibility(View.VISIBLE);
        AlphaAnimation a = new AlphaAnimation(show ? 0f : 1f, show ? 1f : 0f);
        a.setDuration(200);
        a.setFillAfter(false);
        v.startAnimation(a);
        if (!show) {
            uiHandler.postDelayed(() -> v.setVisibility(View.GONE), 200);
        }
    }

    private void showPlaylist() {
        playlistVisible = true;
        controlsVisible = false;
        controlsPanel.setVisibility(View.GONE);
        refreshPlaylistItems();
        playlistPanel.setVisibility(View.VISIBLE);
        playlistPanel.setAlpha(0f);
        playlistPanel.animate().alpha(1f).setDuration(200).start();
        hideHandler.removeCallbacksAndMessages(null);
    }

    private void hidePlaylist() {
        playlistVisible = false;
        playlistPanel.animate().alpha(0f).setDuration(200).withEndAction(() ->
                playlistPanel.setVisibility(View.GONE)).start();
        if (!controlsVisible) toggleControls();
    }

    private void resetHideTimer() {
        hideHandler.removeCallbacksAndMessages(null);
        hideHandler.postDelayed(() -> {
            if (playlistVisible) return;
            controlsVisible = false;
            fade(controlsPanel, false);
        }, 5000);
    }

    private void startProgressUpdater() {
        final Handler h = new Handler(Looper.getMainLooper());
        h.post(new Runnable() {
            @Override public void run() {
                try {
                    if (videoView.getDuration() > 0) {
                        int cur = videoView.getCurrentPosition();
                        int dur = videoView.getDuration();
                        seekBar.setMax(dur);
                        seekBar.setProgress(cur);
                        timeText.setText(formatTime(cur) + " / " + formatTime(dur));
                        playPauseBtn.setText(videoView.isPlaying() ? "⏸" : "▶");
                    }
                } catch (Exception ignored) {}
                h.postDelayed(this, 500);
            }
        });
    }

    private String formatTime(int ms) {
        int sec = ms / 1000;
        int min = sec / 60;
        return String.format(Locale.getDefault(), "%02d:%02d", min, sec % 60);
    }

    // ---- Разрешения ----
    private void checkPermissions() {
        if (Build.VERSION.SDK_INT >= 30) {
            if (!Environment.isExternalStorageManager()) {
                android.content.Intent intent = new android.content.Intent(
                        android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION);
                intent.setData(Uri.parse("package:" + getPackageName()));
                startActivityForResult(intent, 100);
                return;
            }
        }
        startPlayback();
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, android.content.Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == 100) startPlayback();
    }

    private void startPlayback() {
        loadVideos();
        play();
        resetHideTimer();
    }

    // ---- HTTP-сервер для передачи файлов по WiFi ----
    private void startMediaServer() {
        mediaServer = new MediaServer(getMediaFolder());
        try {
            mediaServer.start();
        } catch (Exception e) {
            android.util.Log.w("Brandmen", "MediaServer не запустился: " + e.getMessage());
        }
    }

    @Override
    protected void onDestroy() {
        super.onDestroy();
        if (mediaServer != null) mediaServer.stop();
    }

    // ---- Загрузка видео из выбранной папки ----
    private String getMediaFolder() {
        return prefs.getString(KEY_MEDIA_FOLDER, DEFAULT_MEDIA_FOLDER);
    }

    private void loadVideos() {
        videoFiles.clear();
        String adsDir = getMediaFolder();
        File playlist = new File(adsDir, PLAYLIST_NAME);
        if (playlist.exists()) {
            try {
                BufferedReader br = new BufferedReader(new FileReader(playlist));
                String line;
                while ((line = br.readLine()) != null) {
                    line = line.trim();
                    if (line.startsWith("#") || line.isEmpty()) continue;
                    File f = new File(line);
                    if (!f.isAbsolute()) f = new File(adsDir, line);
                    if (!f.exists()) f = new File(adsDir, f.getName());
                    if (f.exists() && isVideo(f.getName()) && !videoFiles.contains(f)) {
                        videoFiles.add(f);
                    }
                }
                br.close();
            } catch (Exception ignored) {}
        }
        if (videoFiles.isEmpty()) {
            File dir = new File(adsDir);
            File[] files = dir.listFiles();
            if (files != null) {
                List<File> filtered = new ArrayList<>();
                for (File f : files) {
                    if (isVideo(f.getName())) filtered.add(f);
                }
                Collections.sort(filtered, new Comparator<File>() {
                    @Override public int compare(File a, File b) { return a.getName().compareTo(b.getName()); }
                });
                videoFiles.addAll(filtered);
            }
        }
    }

    private boolean isVideo(String name) {
        String n = name.toLowerCase();
        return n.endsWith(".mp4") || n.endsWith(".mkv") || n.endsWith(".mov")
                || n.endsWith(".avi") || n.endsWith(".webm");
    }

    // ---- Синхронизация с Mac ----
    private void startSync() {
        final String ip = prefs.getString(KEY_SERVER_IP, DEFAULT_SERVER_IP);
        Toast.makeText(this, "Связь с " + ip + "...", Toast.LENGTH_SHORT).show();
        new Thread(() -> doSync(ip)).start();
    }

    private void doSync(final String ip) {
        try {
            URL manifestUrl = new URL("http://" + ip + ":5010/api/sync/manifest");
            HttpURLConnection conn = (HttpURLConnection) manifestUrl.openConnection();
            conn.setConnectTimeout(5000);
            conn.setReadTimeout(10000);
            BufferedReader reader = new BufferedReader(new InputStreamReader(
                    new BufferedInputStream(conn.getInputStream())));
            StringBuilder result = new StringBuilder();
            String line;
            while ((line = reader.readLine()) != null) result.append(line);
            reader.close();

            JSONObject json = new JSONObject(result.toString());
            JSONArray files = json.getJSONArray("files");

            String adsDir = getMediaFolder();
            File dir = new File(adsDir);
            if (!dir.exists()) dir.mkdirs();

            List<String> remoteNames = new ArrayList<>();
            int total = files.length();
            for (int i = 0; i < total; i++) {
                JSONObject f = files.getJSONObject(i);
                String name = f.getString("name");
                long size = f.getLong("size");
                remoteNames.add(name);
                File local = new File(dir, name);
                boolean isPlaylist = name.toLowerCase().equals(PLAYLIST_NAME);
                if (!isPlaylist && local.exists() && local.length() == size) continue;
                downloadFile(ip, name, local);
            }

            // Удаляем локальные видео, которых нет в манифесте
            File[] locals = dir.listFiles();
            if (locals != null) {
                for (File l : locals) {
                    if (isVideo(l.getName()) && !remoteNames.contains(l.getName())) {
                        l.delete();
                    }
                }
            }

            runOnUiThread(() -> {
                Toast.makeText(this, "Обновлено", Toast.LENGTH_SHORT).show();
                loadVideos();
                play();
                if (playlistVisible) refreshPlaylistItems();
            });
        } catch (Exception e) {
            runOnUiThread(() -> Toast.makeText(this,
                    "Mac (" + ip + ") не отвечает", Toast.LENGTH_LONG).show());
        }
    }

    private void downloadFile(String ip, String name, File dest) throws Exception {
        URL url = new URL("http://" + ip + ":5010/video/" + Uri.encode(name));
        HttpURLConnection conn = (HttpURLConnection) url.openConnection();
        conn.setConnectTimeout(5000);
        conn.setReadTimeout(60000);
        InputStream is = conn.getInputStream();
        FileOutputStream os = new FileOutputStream(dest);
        byte[] buffer = new byte[8192];
        int len;
        while ((len = is.read(buffer)) != -1) os.write(buffer, 0, len);
        os.close();
        is.close();
    }

    private int dp(int v) {
        return (int) (v * getResources().getDisplayMetrics().density);
    }
}
