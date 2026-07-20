package com.brandmen.ads;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import org.json.JSONObject;
import java.io.*;
import java.net.*;
import java.util.*;

/**
 * Minimal HTTP server (port 5011) for direct WiFi file transfer and remote control.
 *
 * Endpoints:
 *   GET  /version                   — {"version":"0.42.0"}
 *   GET  /files                     — JSON list of video files with sizes
 *   GET  /file/<name>               — download a file
 *   POST /upload/<name>             — upload a file (Content-Length required)
 *   DELETE /file/<name>             — delete a file
 *   GET  /ping                      — {"ok":true}
 *   GET  /health                    — {version,uptimeMs,freeMb,totalMb,playing,index,total,current}
 *   GET  /log                       — последние строки logcat (text/plain) для диагностики
 *   POST /api/control/wake          — wake screen
 *   POST /api/control/sleep         — sleep screen (requires device admin)
 *   POST /api/control/volume?level= — set volume (0..volumeMax)
 *   POST /api/control/brightness?level= — set brightness (0..255)
 *   POST /api/control/launch        — reload playlist and play
 *   POST /api/control/restart       — restart playback from the first clip
 *   POST /api/control/reboot        — reboot device (device owner only)
 *   GET  /api/control/status        — {"volume":8,"volumeMax":15,"brightness":128}
 *   GET  /api/control/now           — {"index":0,"total":3,"name":"ad.mp4","playing":true}
 *   POST /api/brand-pack             — сохраняет имя и акцент бренда для интерфейса плеера
 *   POST /api/update/install        — upload an APK (Content-Length required) and install it
 *                                     (silent if device owner, otherwise one-tap confirm)
 */
public class MediaServer {
    public static final int PORT = 5011;
    public static final String VERSION = "0.0.0";

    public interface ControlCallback {
        void onWake();
        void onSleep();
        void onVolume(int level);
        void onBrightness(int level);
        void onLaunch();
        void onStopPlayback();
        void onRestart();
        void onContentChanged();
        int getVolume();
        int getVolumeMax();
        int getBrightness();
        int getCurrentIndex();
        int getPlaylistCount();
        String getCurrentName();
        boolean isPlaying();
        default int getPlaybackPositionMs() { return -1; }
        void onInstallApk(File apkFile);
        /** Снять с приложения статус device owner (вернуть планшет в обычный режим). */
        default void onClearDeviceOwner() {}
        /** Перезагрузить устройство (только device owner). */
        default void onReboot() {}
    }

    private final String mediaDir;
    private final ControlCallback callback;
    private final Handler mainHandler;
    private final File apkStageDir;
    private final Context appContext;
    private final DeploymentManager deployments;
    private final long startTime = System.currentTimeMillis();
    private ServerSocket serverSocket;
    private Thread acceptThread;
    private volatile boolean running;

    public MediaServer(Context context, String mediaDir, ControlCallback callback) {
        this.mediaDir = mediaDir;
        this.callback = callback;
        this.mainHandler = new Handler(Looper.getMainLooper());
        this.apkStageDir = context.getCacheDir();
        this.appContext = context.getApplicationContext();
        this.deployments = new DeploymentManager(context);
    }

    /** Является ли приложение device owner — тогда обновления ставятся молча. */
    private boolean isDeviceOwner() {
        try {
            android.app.admin.DevicePolicyManager dpm =
                    (android.app.admin.DevicePolicyManager)
                            appContext.getSystemService(Context.DEVICE_POLICY_SERVICE);
            return dpm != null && dpm.isDeviceOwnerApp(appContext.getPackageName());
        } catch (Exception e) {
            return false;
        }
    }

    public void start() throws IOException {
        serverSocket = new ServerSocket();
        serverSocket.setReuseAddress(true);
        serverSocket.bind(new InetSocketAddress("0.0.0.0", PORT));
        running = true;
        acceptThread = new Thread(this::acceptLoop, "MediaServer-accept");
        acceptThread.setDaemon(true);
        acceptThread.start();
    }

    public void stop() {
        running = false;
        try { if (serverSocket != null) serverSocket.close(); } catch (Exception ignored) {}
    }

    private void acceptLoop() {
        while (running) {
            try {
                Socket client = serverSocket.accept();
                client.setSoTimeout(30_000);
                Thread t = new Thread(() -> handleClient(client), "MediaServer-client");
                t.setDaemon(true);
                t.start();
            } catch (Exception e) {
                if (running) android.util.Log.w("MediaServer", "accept: " + e.getMessage());
            }
        }
    }

    private void handleClient(Socket socket) {
        try (socket) {
            InputStream in = socket.getInputStream();
            OutputStream out = new BufferedOutputStream(socket.getOutputStream());

            String requestLine = readAsciiLine(in);
            if (requestLine == null || requestLine.isEmpty()) return;
            String[] parts = requestLine.split(" ");
            if (parts.length < 2) return;
            String method = parts[0].toUpperCase();
            String rawPath = parts[1];

            // Split path and query string
            String[] pathAndQuery = rawPath.split("\\?", 2);
            String path;
            try { path = URLDecoder.decode(pathAndQuery[0], "UTF-8"); }
            catch (Exception e) { path = pathAndQuery[0]; }

            Map<String, String> params = new HashMap<>();
            if (pathAndQuery.length > 1) {
                for (String kv : pathAndQuery[1].split("&")) {
                    int eq = kv.indexOf('=');
                    if (eq > 0) {
                        try {
                            params.put(
                                URLDecoder.decode(kv.substring(0, eq), "UTF-8"),
                                URLDecoder.decode(kv.substring(eq + 1), "UTF-8")
                            );
                        } catch (Exception ignored) {}
                    }
                }
            }

            // Read headers
            int contentLength = -1;
            String authorization = null;
            String line;
            while (!(line = readAsciiLine(in)).isEmpty()) {
                int colon = line.indexOf(':');
                if (colon > 0) {
                    String key = line.substring(0, colon).trim().toLowerCase(Locale.US);
                    String value = line.substring(colon + 1).trim();
                    if (key.equals("content-length")) {
                        try { contentLength = Integer.parseInt(value); } catch (NumberFormatException ignored) {}
                    } else if (key.equals("authorization")) {
                        authorization = value;
                    }
                }
            }

            // Read body for small POST requests (control API).
            // НЕ дочитываем для /upload/ — иначе тело файла (напр. playlist.m3u
            // размером <4096 байт) будет съедено здесь, и handleUpload получит
            // пустой поток → зависание до таймаута сокета.
            boolean isUpload = method.equals("POST")
                    && (path.startsWith("/upload/")
                        || path.startsWith("/api/v2/blob/")
                        || path.equals("/api/update/install"));
            String body = "";
            if (!isUpload && contentLength > 0 && contentLength <= 1024 * 1024) {
                byte[] bodyBytes = new byte[contentLength];
                int total = 0;
                while (total < contentLength) {
                    int n = in.read(bodyBytes, total, contentLength - total);
                    if (n < 0) break;
                    total += n;
                }
                body = new String(bodyBytes, 0, total, "UTF-8");
            }

            // Route
            if (path.startsWith("/api/v2/")
                    && !path.equals("/api/v2/capabilities")
                    && !deployments.authorized(authorization)) {
                sendJson(out, 401, "{\"error\":\"unauthorized\"}");
            } else if (method.equals("GET") && path.equals("/ping")) {
                sendJson(out, 200, "{\"ok\":true}");
            } else if (method.equals("GET") && path.equals("/version")) {
                sendJson(out, 200, "{\"version\":\"" + VERSION + "\"}");
            } else if (method.equals("GET") && path.equals("/health")) {
                handleHealth(out);
            } else if (method.equals("GET") && path.equals("/log")) {
                handleLog(out);
            } else if (method.equals("GET") && path.equals("/files")) {
                handleListFiles(out);
            } else if (method.equals("GET") && path.startsWith("/file/")) {
                handleGetFile(out, sanitize(path.substring(6)));
            } else if (method.equals("POST") && path.startsWith("/upload/")) {
                handleUpload(in, out, sanitize(path.substring(8)), contentLength);
            } else if (method.equals("DELETE") && path.startsWith("/file/")) {
                handleDelete(out, sanitize(path.substring(6)));
            } else if (method.equals("GET") && path.equals("/api/v2/capabilities")) {
                handleV2Capabilities(out);
            } else if (method.equals("GET") && path.equals("/api/v2/status")) {
                handleV2Status(params.get("deployment_id"), out);
            } else if (method.equals("POST") && path.equals("/api/v2/prepare")) {
                handleV2Prepare(body, out);
            } else if (method.equals("POST") && path.startsWith("/api/v2/blob/")) {
                handleV2Blob(
                        sanitize(path.substring("/api/v2/blob/".length())),
                        params, contentLength, in, out);
            } else if (method.equals("POST") && path.equals("/api/v2/commit")) {
                handleV2Commit(body, out);
            } else if (method.equals("POST") && path.equals("/api/v2/rollback")) {
                handleV2Rollback(out);
            } else if (method.equals("POST") && path.equals("/api/update/install")) {
                if (deployments.isOperationActive()) {
                    sendJson(out, 409, "{\"error\":\"deployment_in_progress\"}");
                } else {
                    handleInstallUpload(in, out, contentLength);
                }
            } else if (method.equals("POST") && path.equals("/api/brand-pack")) {
                handleBrandPack(body, out);
            } else if (path.startsWith("/api/control/")) {
                handleControl(method, path.substring("/api/control/".length()), params, body, out);
            } else {
                sendText(out, 404, "Not Found");
            }
            out.flush();
        } catch (Exception e) {
            android.util.Log.w("MediaServer", "handle: " + e.getMessage());
        }
    }

    // ---- Control handlers ----

    private void handleControl(String method, String action, Map<String, String> params,
                               String body, OutputStream out) throws IOException {
        if (action.equals("status") && method.equals("GET")) {
            if (callback == null) { sendJson(out, 200, "{\"volume\":8,\"volumeMax\":15,\"brightness\":128}"); return; }
            int vol = callback.getVolume();
            int volMax = callback.getVolumeMax();
            int bright = callback.getBrightness();
            sendJson(out, 200, "{\"volume\":" + vol + ",\"volumeMax\":" + volMax + ",\"brightness\":" + bright + "}");
            return;
        }
        if (action.equals("now") && method.equals("GET")) {
            if (callback == null) { sendJson(out, 503, "{\"error\":\"no_callback\"}"); return; }
            int index = callback.getCurrentIndex();
            int total = callback.getPlaylistCount();
            String name = callback.getCurrentName();
            boolean playing = callback.isPlaying();
            sendJson(out, 200, "{\"index\":" + index + ",\"total\":" + total
                + ",\"name\":\"" + escJson(name == null ? "" : name)
                + "\",\"playing\":" + playing
                + ",\"playbackEnabled\":" + Kiosk.isPlaybackEnabled(appContext) + "}");
            return;
        }
        if (!method.equals("POST")) { sendText(out, 405, "Method Not Allowed"); return; }
        if (callback == null) { sendJson(out, 503, "{\"error\":\"no_callback\"}"); return; }

        switch (action) {
            case "wake":
                mainHandler.post(callback::onWake);
                sendJson(out, 200, "{\"ok\":true}");
                break;
            case "sleep":
                mainHandler.post(callback::onSleep);
                sendJson(out, 200, "{\"ok\":true}");
                break;
            case "launch":
                mainHandler.post(callback::onLaunch);
                sendJson(out, 200, "{\"ok\":true}");
                break;
            case "stop":
                mainHandler.post(callback::onStopPlayback);
                sendJson(out, 200, "{\"ok\":true}");
                break;
            case "restart":
                mainHandler.post(callback::onRestart);
                sendJson(out, 200, "{\"ok\":true}");
                break;
            case "unmanage":
                // Снять device owner — планшет снова обычный (можно включить
                // «Автозапуск» вручную в Безопасности MIUI).
                mainHandler.post(callback::onClearDeviceOwner);
                sendJson(out, 200, "{\"ok\":true}");
                break;
            case "reboot":
                // Перезагрузка по команде оператора (без ADB). Сработает только на
                // device owner; ответ отправляем ДО ребута.
                if (deployments.isOperationActive()) {
                    sendJson(out, 409, "{\"error\":\"deployment_in_progress\"}");
                    break;
                }
                sendJson(out, 200, "{\"ok\":true}");
                mainHandler.post(callback::onReboot);
                break;
            case "volume": {
                int level = parseParam(params.get("level"), parseJsonInt(body, "level", -1));
                if (level < 0) { sendJson(out, 400, "{\"error\":\"missing level\"}"); return; }
                final int l = level;
                mainHandler.post(() -> callback.onVolume(l));
                sendJson(out, 200, "{\"ok\":true}");
                break;
            }
            case "brightness": {
                int level = parseParam(params.get("level"), parseJsonInt(body, "level", -1));
                if (level < 0) { sendJson(out, 400, "{\"error\":\"missing level\"}"); return; }
                final int l = level;
                mainHandler.post(() -> callback.onBrightness(l));
                sendJson(out, 200, "{\"ok\":true}");
                break;
            }
            default:
                sendText(out, 404, "Not Found");
        }
    }

    // ---- Health / diagnostics ----

    private String cachedSignature;

    /** SHA-256 отпечаток подписи APK — ПК сравнивает с эталоном CI-сборки,
     *  чтобы сразу видеть «обновления не встанут поверх» (чужая подпись). */
    private String signatureSha256() {
        if (cachedSignature != null) return cachedSignature;
        try {
            android.content.pm.PackageManager pm = appContext.getPackageManager();
            android.content.pm.Signature[] sigs;
            if (android.os.Build.VERSION.SDK_INT >= 28) {
                android.content.pm.SigningInfo si = pm.getPackageInfo(
                        appContext.getPackageName(),
                        android.content.pm.PackageManager.GET_SIGNING_CERTIFICATES).signingInfo;
                sigs = si != null ? si.getApkContentsSigners() : null;
            } else {
                sigs = pm.getPackageInfo(appContext.getPackageName(),
                        android.content.pm.PackageManager.GET_SIGNATURES).signatures;
            }
            if (sigs != null && sigs.length > 0) {
                java.security.MessageDigest md = java.security.MessageDigest.getInstance("SHA-256");
                byte[] d = md.digest(sigs[0].toByteArray());
                StringBuilder sb = new StringBuilder();
                for (byte b : d) sb.append(String.format("%02X", b));
                cachedSignature = sb.toString();
                return cachedSignature;
            }
        } catch (Exception ignored) {}
        cachedSignature = "";
        return cachedSignature;
    }

    private int batteryLevel() {
        try {
            android.os.BatteryManager bm = (android.os.BatteryManager)
                    appContext.getSystemService(Context.BATTERY_SERVICE);
            if (bm != null) {
                int v = bm.getIntProperty(
                        android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY);
                if (v > 0) return v;
            }
        } catch (Exception ignored) {}
        return -1;
    }

    /** Разрешена ли этому приложению установка APK (нужно для окна обновления). */
    private boolean canRequestInstalls() {
        try {
            if (android.os.Build.VERSION.SDK_INT < 26) return true;
            return appContext.getPackageManager().canRequestPackageInstalls();
        } catch (Exception e) {
            return false;
        }
    }

    /** Исключено ли приложение из оптимизации батареи (иначе прошивка убивает). */
    private boolean isBatteryExempt() {
        try {
            if (android.os.Build.VERSION.SDK_INT < 23) return true;
            android.os.PowerManager pm = (android.os.PowerManager)
                    appContext.getSystemService(Context.POWER_SERVICE);
            return pm != null && pm.isIgnoringBatteryOptimizations(
                    appContext.getPackageName());
        } catch (Exception e) {
            return false;
        }
    }

    /** Есть ли «поверх других приложений» (бутстрап вывода плеера из фона). */
    private boolean canDrawOverlays() {
        try {
            if (android.os.Build.VERSION.SDK_INT < 23) return true;
            return android.provider.Settings.canDrawOverlays(appContext);
        } catch (Exception e) {
            return false;
        }
    }

    private void handleHealth(OutputStream out) throws IOException {
        long uptime = System.currentTimeMillis() - startTime;
        long freeMb = 0, totalMb = 0;
        try {
            android.os.StatFs fs = new android.os.StatFs(mediaDir);
            freeMb = fs.getAvailableBytes() / (1024 * 1024);
            totalMb = fs.getTotalBytes() / (1024 * 1024);
        } catch (Exception ignored) {}
        int idx = -1, total = 0;
        String name = "";
        boolean playing = false;
        int positionMs = -1;
        if (callback != null) {
            idx = callback.getCurrentIndex();
            total = callback.getPlaylistCount();
            name = callback.getCurrentName();
            playing = callback.isPlaying();
            positionMs = callback.getPlaybackPositionMs();
        }
        sendJson(out, 200, "{\"version\":\"" + VERSION + "\""
                + ",\"uptimeMs\":" + uptime
                + ",\"freeMb\":" + freeMb
                + ",\"totalMb\":" + totalMb
                + ",\"playing\":" + playing
                + ",\"playbackEnabled\":" + Kiosk.isPlaybackEnabled(appContext)
                + ",\"positionMs\":" + positionMs
                + ",\"index\":" + idx
                + ",\"total\":" + total
                + ",\"deviceOwner\":" + isDeviceOwner()
                + ",\"online\":" + NetworkWatchdog.isOnline(appContext)
                + ",\"battery\":" + batteryLevel()
                + ",\"signature\":\"" + signatureSha256() + "\""
                + ",\"canInstall\":" + canRequestInstalls()
                + ",\"batteryExempt\":" + isBatteryExempt()
                + ",\"overlay\":" + canDrawOverlays()
                + ",\"deviceId\":\"" + escJson(deployments.deviceId()) + "\""
                + ",\"protocolVersion\":" + DeploymentManager.PROTOCOL_VERSION
                + ",\"activeDeploymentId\":\""
                    + escJson(deployments.activeDeploymentId()) + "\""
                + ",\"playlistHash\":\""
                    + escJson(deployments.activePlaylistHash()) + "\""
                + ",\"currentFileSha256\":\""
                    + escJson(deployments.hashForActiveLogicalName(name == null ? "" : name)) + "\""
                + ",\"brand\":\"" + escJson(BrandConfig.name(appContext)) + "\""
                + ",\"accent\":\"" + escJson(BrandConfig.accent(appContext)) + "\""
                + ",\"current\":\"" + escJson(name == null ? "" : name) + "\"}");
    }

    // ---- Deployment protocol v2 ----

    private void handleV2Capabilities(OutputStream out) throws IOException {
        try {
            sendJson(out, 200, deployments.capabilities().toString());
        } catch (Exception e) {
            sendV2Error(out, e);
        }
    }

    private void handleV2Status(String deploymentId, OutputStream out) throws IOException {
        try {
            sendJson(out, 200, deployments.status(deploymentId).toString());
        } catch (Exception e) {
            sendV2Error(out, e);
        }
    }

    private void handleV2Prepare(String body, OutputStream out) throws IOException {
        try {
            sendJson(out, 200, deployments.prepare(body).toString());
        } catch (Exception e) {
            sendV2Error(out, e);
        }
    }

    private void handleV2Blob(String hash, Map<String, String> params,
                              int contentLength, InputStream in, OutputStream out)
            throws IOException {
        try {
            long offset = Long.parseLong(params.getOrDefault("offset", "0"));
            long total = Long.parseLong(params.getOrDefault("total", "-1"));
            JSONObject result =
                    deployments.uploadBlob(hash, offset, total, contentLength, in);
            int code = result.has("error") ? 409 : 200;
            sendJson(out, code, result.toString());
        } catch (Exception e) {
            sendV2Error(out, e);
        }
    }

    private void handleV2Commit(String body, OutputStream out) throws IOException {
        try {
            JSONObject request = new JSONObject(body);
            JSONObject result =
                    deployments.commit(request.getString("deployment_id"));
            sendJson(out, 200, result.toString());
            // Перечитать manifest, не меняя операторское состояние
            // «реклама включена/выключена».
            if (callback != null) mainHandler.post(callback::onContentChanged);
        } catch (Exception e) {
            sendV2Error(out, e);
        }
    }

    private void handleV2Rollback(OutputStream out) throws IOException {
        try {
            JSONObject result = deployments.rollback();
            sendJson(out, 200, result.toString());
            if (callback != null) mainHandler.post(callback::onContentChanged);
        } catch (Exception e) {
            sendV2Error(out, e);
        }
    }

    private void sendV2Error(OutputStream out, Exception e) throws IOException {
        String code = e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage();
        int status = (e instanceof IllegalArgumentException) ? 400
                : (e instanceof SecurityException) ? 422
                : (e instanceof FileNotFoundException) ? 404
                : (e instanceof IllegalStateException) ? 409 : 500;
        android.util.Log.w("Deployment", code, e);
        sendJson(out, status, "{\"error\":\"" + escJson(code) + "\"}");
    }

    /** Сохраняет бренд-пакет, переданный пультом. Данные переживают перезагрузку. */
    private void handleBrandPack(String body, OutputStream out) throws IOException {
        if (body == null || body.trim().isEmpty()) {
            sendText(out, 400, "Bad Request");
            return;
        }
        try {
            BrandConfig.apply(appContext, body);
            sendJson(out, 200, "{\"ok\":true}");
        } catch (Exception e) {
            android.util.Log.w("MediaServer", "brand pack: " + e.getMessage());
            sendJson(out, 400, "{\"error\":\"invalid brand pack\"}");
        }
    }

    private void handleLog(OutputStream out) throws IOException {
        StringBuilder sb = new StringBuilder();
        try {
            // Приложение читает свой собственный logcat — для удалённой диагностики.
            Process p = Runtime.getRuntime().exec(
                    new String[]{"logcat", "-d", "-v", "time", "-t", "500"});
            try (BufferedReader r = new BufferedReader(
                    new InputStreamReader(p.getInputStream(), "UTF-8"))) {
                String line;
                while ((line = r.readLine()) != null) sb.append(line).append('\n');
            }
        } catch (Exception e) {
            sb.append("logcat error: ").append(e.getMessage());
        }
        sendText(out, 200, sb.toString());
    }

    // ---- File handlers ----

    private void handleListFiles(OutputStream out) throws IOException {
        File dir = new File(mediaDir);
        File[] files = dir.listFiles();
        StringBuilder sb = new StringBuilder("[");
        boolean first = true;
        if (files != null) {
            Arrays.sort(files, (a, b) -> a.getName().compareToIgnoreCase(b.getName()));
            for (File f : files) {
                if (!f.isFile()) continue;
                String n = f.getName().toLowerCase(Locale.US);
                if (!n.endsWith(".mp4") && !n.endsWith(".mkv") && !n.endsWith(".mov")
                        && !n.endsWith(".avi") && !n.endsWith(".webm")) continue;
                if (!first) sb.append(",");
                sb.append("{\"name\":\"").append(escJson(f.getName()))
                  .append("\",\"size\":").append(f.length()).append("}");
                first = false;
            }
        }
        sb.append("]");
        sendJson(out, 200, sb.toString());
    }

    private void handleGetFile(OutputStream out, String filename) throws IOException {
        if (filename.isEmpty()) { sendText(out, 400, "Bad Request"); return; }
        File f = new File(mediaDir, filename);
        if (!f.exists() || !f.isFile()) { sendText(out, 404, "Not Found"); return; }
        String header = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: application/octet-stream\r\n"
                + "Content-Length: " + f.length() + "\r\n"
                + "Content-Disposition: attachment; filename=\"" + escJson(filename) + "\"\r\n"
                + "Connection: close\r\n\r\n";
        out.write(header.getBytes("US-ASCII"));
        try (FileInputStream fis = new FileInputStream(f)) {
            byte[] buf = new byte[65536];
            int n;
            while ((n = fis.read(buf)) != -1) out.write(buf, 0, n);
        }
    }

    private void handleUpload(InputStream in, OutputStream out,
                              String filename, int contentLength) throws IOException {
        if (filename.isEmpty() || contentLength < 0) {
            sendText(out, 400, "Bad Request"); return;
        }
        File dest = new File(mediaDir, filename + ".part");
        new File(mediaDir).mkdirs();
        int remaining = contentLength;
        try (FileOutputStream fos = new FileOutputStream(dest)) {
            byte[] buf = new byte[65536];
            while (remaining > 0) {
                int toRead = Math.min(buf.length, remaining);
                int n = in.read(buf, 0, toRead);
                if (n < 0) break;
                fos.write(buf, 0, n);
                remaining -= n;
            }
            fos.flush();
            fos.getFD().sync();
        }
        // Никогда не публикуем оборванную загрузку. Раньше сервер отвечал 200
        // и заменял рабочий ролик даже при EOF до заявленного Content-Length.
        if (remaining != 0 || dest.length() != contentLength) {
            long received = dest.length();
            if (!dest.delete()) dest.deleteOnExit();
            android.util.Log.w("MediaServer", "upload incomplete " + filename
                    + ": expected=" + contentLength + " received=" + received);
            sendJson(out, 400, "{\"error\":\"incomplete_upload\",\"expected\":"
                    + contentLength + ",\"received\":" + received + "}");
            return;
        }
        File final_ = new File(mediaDir, filename);
        File backup = new File(mediaDir, filename + ".previous");
        if (backup.exists()) backup.delete();
        boolean hadFinal = final_.exists();
        if (hadFinal && !final_.renameTo(backup)) {
            dest.delete();
            sendJson(out, 500, "{\"error\":\"cannot_stage_previous\"}");
            return;
        }
        if (!dest.renameTo(final_)) {
            if (hadFinal) backup.renameTo(final_);
            dest.delete();
            sendJson(out, 500, "{\"error\":\"cannot_publish_upload\"}");
            return;
        }
        if (backup.exists()) backup.delete();
        sendJson(out, 200, "{\"ok\":true,\"name\":\"" + escJson(filename) + "\"}");
    }

    private void handleInstallUpload(InputStream in, OutputStream out, int contentLength)
            throws IOException {
        if (contentLength <= 0) { sendText(out, 400, "Bad Request"); return; }
        apkStageDir.mkdirs();
        File apk = new File(apkStageDir, "remote-update.apk");
        File part = new File(apkStageDir, "remote-update.apk.part");
        int remaining = contentLength;
        try (FileOutputStream fos = new FileOutputStream(part)) {
            byte[] buf = new byte[65536];
            while (remaining > 0) {
                int n = in.read(buf, 0, Math.min(buf.length, remaining));
                if (n < 0) break;
                fos.write(buf, 0, n);
                remaining -= n;
            }
            fos.flush();
            fos.getFD().sync();
        }
        if (remaining != 0 || part.length() != contentLength) {
            long received = part.length();
            if (!part.delete()) part.deleteOnExit();
            sendJson(out, 400, "{\"error\":\"incomplete_upload\",\"expected\":"
                    + contentLength + ",\"received\":" + received + "}");
            return;
        }
        if (apk.exists()) apk.delete();
        if (!part.renameTo(apk)) {
            sendJson(out, 500, "{\"error\":\"cannot_publish_apk\"}");
            return;
        }
        if (callback != null) {
            final File f = apk;
            mainHandler.post(() -> callback.onInstallApk(f));
        }
        sendJson(out, 200, "{\"ok\":true}");
    }

    private void handleDelete(OutputStream out, String filename) throws IOException {
        if (filename.isEmpty()) { sendText(out, 400, "Bad Request"); return; }
        File f = new File(mediaDir, filename);
        boolean ok = f.exists() && f.delete();
        sendJson(out, ok ? 200 : 404, "{\"ok\":" + ok + "}");
    }

    // ---- Helpers ----

    private static int parseParam(String paramVal, int fallback) {
        if (paramVal == null) return fallback;
        try { return Integer.parseInt(paramVal.trim()); } catch (NumberFormatException e) { return fallback; }
    }

    private static int parseJsonInt(String body, String key, int defaultVal) {
        if (body == null || body.isEmpty()) return defaultVal;
        try { return new org.json.JSONObject(body).optInt(key, defaultVal); }
        catch (Exception e) { return defaultVal; }
    }

    private void sendJson(OutputStream out, int code, String body) throws IOException {
        byte[] data = body.getBytes("UTF-8");
        String header = "HTTP/1.1 " + code + " " + statusText(code) + "\r\n"
                + "Content-Type: application/json; charset=utf-8\r\n"
                + "Content-Length: " + data.length + "\r\n"
                + "Access-Control-Allow-Origin: *\r\n"
                + "Connection: close\r\n\r\n";
        out.write(header.getBytes("US-ASCII"));
        out.write(data);
    }

    private void sendText(OutputStream out, int code, String body) throws IOException {
        byte[] data = body.getBytes("UTF-8");
        String header = "HTTP/1.1 " + code + " " + statusText(code) + "\r\n"
                + "Content-Type: text/plain; charset=utf-8\r\n"
                + "Content-Length: " + data.length + "\r\n"
                + "Connection: close\r\n\r\n";
        out.write(header.getBytes("US-ASCII"));
        out.write(data);
    }

    private static String statusText(int code) {
        switch (code) {
            case 200: return "OK";
            case 400: return "Bad Request";
            case 401: return "Unauthorized";
            case 404: return "Not Found";
            case 405: return "Method Not Allowed";
            case 409: return "Conflict";
            case 422: return "Unprocessable Entity";
            case 500: return "Internal Server Error";
            case 503: return "Service Unavailable";
            default: return "Error";
        }
    }

    private static String readAsciiLine(InputStream in) throws IOException {
        StringBuilder sb = new StringBuilder();
        int b;
        while ((b = in.read()) != -1) {
            if (b == '\r') continue;
            if (b == '\n') break;
            sb.append((char) b);
        }
        return sb.toString();
    }

    private static String sanitize(String name) {
        return new File(name).getName();
    }

    private static String escJson(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }
}
