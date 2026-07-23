package com.brandmen.ads;

import android.content.Context;
import android.net.wifi.WifiManager;
import android.os.Handler;
import android.provider.Settings;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

/**
 * Outbound-канал управления: планшет САМ ходит на сервер, забирает команды
 * (poll) и шлёт результат (ack). Снимает зависимость «ПК должен дотянуться до
 * планшета в локалке» — пока у планшета есть интернет, он управляем, даже если
 * сменился IP/подсеть или он за NAT.
 *
 * Сервер (тот же приёмник логов):
 *   GET  {SERVER}/commands/poll?site=<id>&token=&ip=&v=&model=  -> [{id,cmd,args}]
 *   POST {SERVER}/commands/ack?site=<id>&token=  body {id,ok,result}
 *
 * Команды выполняются через тот же {@link MediaServer.ControlCallback}, что и
 * локальный HTTP-сервер, поэтому поведение идентично «ПК → планшет».
 */
final class CommandPoller {
    private static final String TAG = "CommandPoller";
    private static final String SERVER = "https://185.50.203.112";
    private static final String TOKEN = "933897b46de4e38806e6d6669d768e9c";
    private static final long POLL_MS = 12_000L;
    private static final String SERVER_CERT_SHA256 =
            "66d54bc380ef63b293ba1a116d62899404400ec78ad98107c20e81823ec160f1";

    private final Context app;
    private final MediaServer.ControlCallback cb;
    private final Handler main;
    private volatile boolean running;
    private Thread thread;

    CommandPoller(Context ctx, MediaServer.ControlCallback cb, Handler main) {
        this.app = ctx.getApplicationContext();
        this.cb = cb;
        this.main = main;
    }

    void start() {
        if (running) return;
        running = true;
        thread = new Thread(this::loop, "CommandPoller");
        thread.setDaemon(true);
        thread.start();
    }

    void stop() {
        running = false;
        if (thread != null) thread.interrupt();
    }

    private void loop() {
        while (running) {
            try { pollOnce(); }
            catch (Exception e) { android.util.Log.w(TAG, "poll: " + e.getMessage()); }
            try { Thread.sleep(POLL_MS); }
            catch (InterruptedException e) { break; }
        }
    }

    /** Стабильный id планшета (переживает смену IP и обновления). */
    private String siteId() {
        String id = null;
        try { id = Settings.Secure.getString(app.getContentResolver(), Settings.Secure.ANDROID_ID); }
        catch (Exception ignored) {}
        if (id == null || id.isEmpty()) id = "unknown";
        return "tab-" + id;
    }

    private String wifiIp() {
        try {
            WifiManager wifi = (WifiManager) app.getSystemService(Context.WIFI_SERVICE);
            if (wifi == null) return "";
            int ip = wifi.getConnectionInfo().getIpAddress();
            if (ip == 0) return "";
            return (ip & 0xff) + "." + ((ip >> 8) & 0xff) + "."
                    + ((ip >> 16) & 0xff) + "." + ((ip >> 24) & 0xff);
        } catch (Exception e) {
            return "";
        }
    }

    private void pollOnce() throws Exception {
        JSONObject state = stateSnapshot();
        String url = SERVER + "/commands/poll?site=" + enc(siteId())
                + "&device_id=" + enc(siteId())
                + "&ip=" + enc(wifiIp())
                + "&v=" + enc(MediaServer.VERSION)
                + "&model=" + enc(android.os.Build.MODEL)
                + "&playing=" + state.optBoolean("playing", false)
                + "&playback_enabled=" + state.optBoolean("playback_enabled", false)
                + "&current=" + enc(state.optString("current", ""))
                + "&index=" + state.optInt("index", -1)
                + "&total=" + state.optInt("total", 0)
                + "&device_owner=" + state.optBoolean("device_owner", false);
        String resp = httpGet(url);
        if (resp == null || resp.isEmpty()) return;
        JSONArray arr = new JSONArray(resp);
        for (int i = 0; i < arr.length(); i++) {
            JSONObject c = arr.optJSONObject(i);
            if (c == null) continue;
            int id = c.optInt("id", -1);
            String cmd = c.optString("cmd", "");
            JSONObject args = c.optJSONObject("args");
            ExecutionResult result = execute(cmd, args);
            ack(id, result.ok, result.message);
        }
    }

    /** Выполняет команду на UI-потоке и только после этого подтверждает её серверу. */
    private ExecutionResult execute(String cmd, JSONObject args) {
        if (cb == null) return ExecutionResult.error("no callback");
        try {
            if ("status".equals(cmd)) {
                return ExecutionResult.ok(stateSnapshot().toString());
            }
            final Runnable action;
            switch (cmd) {
                case "launch":    action = cb::onLaunch; break;
                case "stop":      action = cb::onStopPlayback; break;
                case "restart":   action = cb::onRestartPlayback; break;
                case "wake":      action = cb::onWake; break;
                case "sleep":     action = cb::onSleep; break;
                case "reboot":    action = cb::onReboot; break;
                case "unmanage":  action = cb::onClearDeviceOwner; break;
                case "volume": {
                    int lvl = args != null ? args.optInt("level", -1) : -1;
                    if (lvl < 0) return ExecutionResult.error("missing level");
                    action = () -> cb.onVolume(lvl);
                    break;
                }
                case "brightness": {
                    int lvl = args != null ? args.optInt("level", -1) : -1;
                    if (lvl < 0) return ExecutionResult.error("missing level");
                    action = () -> cb.onBrightness(lvl);
                    break;
                }
                default:
                    return ExecutionResult.error("unknown cmd: " + cmd);
            }
            CountDownLatch done = new CountDownLatch(1);
            AtomicReference<Throwable> failure = new AtomicReference<>();
            main.post(() -> {
                try { action.run(); }
                catch (Throwable error) { failure.set(error); }
                finally { done.countDown(); }
            });
            if (!done.await(5, TimeUnit.SECONDS)) {
                return ExecutionResult.error("main thread timeout");
            }
            if (failure.get() != null) {
                return ExecutionResult.error("command failed: " + failure.get().getMessage());
            }
            return ExecutionResult.ok(stateSnapshot().toString());
        } catch (Exception e) {
            return ExecutionResult.error("err: " + e.getMessage());
        }
    }

    /** Снимок фактического состояния. Callback читается на main thread. */
    private JSONObject stateSnapshot() {
        final JSONObject state = new JSONObject();
        CountDownLatch done = new CountDownLatch(1);
        main.post(() -> {
            try {
                state.put("device_id", siteId());
                state.put("playing", cb != null && cb.isPlaying());
                state.put("playback_enabled", Kiosk.isPlaybackEnabled(app));
                state.put("current", cb == null ? "" : cb.getCurrentName());
                state.put("index", cb == null ? -1 : cb.getCurrentIndex());
                state.put("total", cb == null ? 0 : cb.getPlaylistCount());
                state.put("device_owner", Kiosk.isDeviceOwner(app));
            } catch (Exception e) {
                try { state.put("error", String.valueOf(e.getMessage())); }
                catch (Exception ignored) {}
            } finally {
                done.countDown();
            }
        });
        try { done.await(3, TimeUnit.SECONDS); }
        catch (InterruptedException e) { Thread.currentThread().interrupt(); }
        return state;
    }

    private static final class ExecutionResult {
        final boolean ok;
        final String message;
        private ExecutionResult(boolean ok, String message) {
            this.ok = ok;
            this.message = message;
        }
        static ExecutionResult ok(String message) {
            return new ExecutionResult(true, message == null ? "ok" : message);
        }
        static ExecutionResult error(String message) {
            return new ExecutionResult(false, message == null ? "error" : message);
        }
    }

    private void ack(int id, boolean ok, String result) {
        try {
            String url = SERVER + "/commands/ack?site=" + enc(siteId());
            JSONObject b = new JSONObject();
            b.put("id", id);
            b.put("ok", ok);
            b.put("result", result == null ? "" : result);
            httpPost(url, b.toString());
        } catch (Exception e) {
            android.util.Log.w(TAG, "ack: " + e.getMessage());
        }
    }

    // ---- HTTP (доверяем нашему самоподписанному серверу) ----

    private String httpGet(String urlStr) throws Exception {
        HttpURLConnection c = open(urlStr);
        c.setRequestMethod("GET");
        c.setConnectTimeout(10000);
        c.setReadTimeout(15000);
        try {
            if (c.getResponseCode() != 200) return null;
            return readAll(c);
        } finally {
            c.disconnect();
        }
    }

    private void httpPost(String urlStr, String body) throws Exception {
        HttpURLConnection c = open(urlStr);
        c.setRequestMethod("POST");
        c.setConnectTimeout(10000);
        c.setReadTimeout(15000);
        c.setDoOutput(true);
        c.setRequestProperty("Content-Type", "application/json; charset=utf-8");
        try (OutputStream os = c.getOutputStream()) {
            os.write(body.getBytes("UTF-8"));
        }
        try { c.getResponseCode(); } finally { c.disconnect(); }
    }

    /** Открывает соединение; для https ставит доверие к нашему серверу (самоподписанный серт). */
    private HttpURLConnection open(String urlStr) throws Exception {
        URL url = new URL(urlStr);
        HttpURLConnection c = (HttpURLConnection) url.openConnection();
        // Секрет не попадает в URL, историю прокси и access-логи.
        c.setRequestProperty("Authorization", "Bearer " + TOKEN);
        if (c instanceof HttpsURLConnection) {
            HttpsURLConnection https = (HttpsURLConnection) c;
            https.setSSLSocketFactory(pinnedTls().getSocketFactory());
            // URL использует IP, поэтому проверку имени заменяет строгий pin
            // конкретного сертификата.
            https.setHostnameVerifier((h, s) -> true);
        }
        return c;
    }

    private SSLContext pinnedTls() throws Exception {
        SSLContext ctx = SSLContext.getInstance("TLS");
        ctx.init(null, new TrustManager[]{new PinnedTrustManager()},
                new java.security.SecureRandom());
        return ctx;
    }

    private static final class PinnedTrustManager implements X509TrustManager {
        @Override public void checkClientTrusted(X509Certificate[] chain, String authType)
                throws java.security.cert.CertificateException {
            throw new java.security.cert.CertificateException(
                    "client certificate not accepted");
        }

        @Override public void checkServerTrusted(X509Certificate[] chain, String authType)
                throws java.security.cert.CertificateException {
            if (chain == null || chain.length == 0) {
                throw new java.security.cert.CertificateException(
                        "empty server certificate");
            }
            try {
                MessageDigest md = MessageDigest.getInstance("SHA-256");
                byte[] digest = md.digest(chain[0].getEncoded());
                StringBuilder hex = new StringBuilder();
                for (byte b : digest) hex.append(String.format("%02x", b));
                if (!SERVER_CERT_SHA256.equals(hex.toString())) {
                    throw new java.security.cert.CertificateException(
                            "server certificate pin mismatch");
                }
            } catch (java.security.cert.CertificateException e) {
                throw e;
            } catch (Exception e) {
                throw new java.security.cert.CertificateException(e);
            }
        }

        @Override public X509Certificate[] getAcceptedIssuers() {
            return new X509Certificate[0];
        }
    }

    private static String readAll(HttpURLConnection c) throws Exception {
        StringBuilder sb = new StringBuilder();
        try (BufferedReader r = new BufferedReader(new InputStreamReader(c.getInputStream(), "UTF-8"))) {
            String line;
            while ((line = r.readLine()) != null) sb.append(line);
        }
        return sb.toString();
    }

    private static String enc(String s) {
        try { return URLEncoder.encode(s == null ? "" : s, "UTF-8"); }
        catch (Exception e) { return ""; }
    }
}
