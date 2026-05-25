package com.brandmen.ads;

import android.util.Log;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;

/**
 * Checks GitHub releases for a newer APK and downloads it.
 */
public class UpdateChecker {
    private static final String RELEASES_URL =
            "https://api.github.com/repos/xykaxayc/brandmen-control/releases?per_page=15";
    private static final String TAG = "UpdateChecker";

    public static class UpdateInfo {
        public final String version;
        public final String downloadUrl;
        UpdateInfo(String version, String downloadUrl) {
            this.version = version;
            this.downloadUrl = downloadUrl;
        }
    }

    public interface CheckCallback {
        void onUpdateAvailable(UpdateInfo info);
        void onUpToDate();
        void onError(String message);
    }

    public interface DownloadCallback {
        void onProgress(int percent);
        void onDone(File apkFile);
        void onError(String message);
    }

    /** Async: finds the newest APK release newer than currentVersion. */
    public static void checkAsync(String currentVersion, CheckCallback cb) {
        new Thread(() -> {
            try {
                UpdateInfo info = findNewestApk(currentVersion);
                if (info != null) cb.onUpdateAvailable(info);
                else cb.onUpToDate();
            } catch (Exception e) {
                Log.w(TAG, "check: " + e.getMessage());
                cb.onError(e.getMessage());
            }
        }, "UpdateChecker-check").start();
    }

    /** Async: downloads APK to destFile, reports progress. */
    public static void downloadAsync(String url, File destFile, DownloadCallback cb) {
        new Thread(() -> {
            try {
                destFile.getParentFile().mkdirs();
                File part = new File(destFile.getPath() + ".part");
                HttpURLConnection conn = openFollowingRedirects(url);
                int total = conn.getContentLength();
                try (InputStream in = conn.getInputStream();
                     FileOutputStream out = new FileOutputStream(part)) {
                    byte[] buf = new byte[65536];
                    int read, downloaded = 0;
                    while ((read = in.read(buf)) != -1) {
                        out.write(buf, 0, read);
                        downloaded += read;
                        if (total > 0) cb.onProgress(downloaded * 100 / total);
                    }
                }
                if (destFile.exists()) destFile.delete();
                part.renameTo(destFile);
                cb.onDone(destFile);
            } catch (Exception e) {
                Log.w(TAG, "download: " + e.getMessage());
                cb.onError(e.getMessage());
            }
        }, "UpdateChecker-download").start();
    }

    // ---- internals ----

    private static UpdateInfo findNewestApk(String currentVersion) throws Exception {
        String body = fetch(RELEASES_URL);
        JSONArray releases = new JSONArray(body);
        for (int i = 0; i < releases.length(); i++) {
            JSONObject rel = releases.getJSONObject(i);
            String tag = rel.optString("tag_name", "");
            String version = tag.startsWith("v") ? tag.substring(1) : tag;
            if (!isNewer(version, currentVersion)) continue;
            JSONArray assets = rel.optJSONArray("assets");
            if (assets == null) continue;
            for (int j = 0; j < assets.length(); j++) {
                JSONObject asset = assets.getJSONObject(j);
                String name = asset.optString("name", "").toLowerCase();
                if (name.endsWith(".apk")) {
                    String url = asset.optString("browser_download_url", "");
                    if (!url.isEmpty()) return new UpdateInfo(version, url);
                }
            }
        }
        return null;
    }

    private static String fetch(String urlStr) throws Exception {
        HttpURLConnection conn = (HttpURLConnection) new URL(urlStr).openConnection();
        conn.setConnectTimeout(8000);
        conn.setReadTimeout(10000);
        conn.setRequestProperty("User-Agent", "BrandmenAds/" + MediaServer.VERSION);
        try (BufferedReader r = new BufferedReader(
                new InputStreamReader(conn.getInputStream(), "UTF-8"))) {
            StringBuilder sb = new StringBuilder();
            String line;
            while ((line = r.readLine()) != null) sb.append(line);
            return sb.toString();
        }
    }

    private static HttpURLConnection openFollowingRedirects(String urlStr) throws Exception {
        for (int i = 0; i < 6; i++) {
            HttpURLConnection conn = (HttpURLConnection) new URL(urlStr).openConnection();
            conn.setConnectTimeout(8000);
            conn.setReadTimeout(120_000);
            conn.setInstanceFollowRedirects(false);
            conn.setRequestProperty("User-Agent", "BrandmenAds/" + MediaServer.VERSION);
            int code = conn.getResponseCode();
            if (code / 100 == 3) {
                urlStr = conn.getHeaderField("Location");
                conn.disconnect();
            } else {
                return conn;
            }
        }
        throw new IOException("Too many redirects");
    }

    static boolean isNewer(String remote, String local) {
        if (remote.isEmpty() || remote.equals("0.0.0")) return false;
        int[] r = parse(remote), l = parse(local);
        for (int i = 0; i < 3; i++) {
            if (r[i] > l[i]) return true;
            if (r[i] < l[i]) return false;
        }
        return false;
    }

    private static int[] parse(String v) {
        String[] parts = v.split("\\.");
        int[] n = new int[3];
        for (int i = 0; i < 3 && i < parts.length; i++) {
            try { n[i] = Integer.parseInt(parts[i]); } catch (NumberFormatException ignored) {}
        }
        return n;
    }
}
