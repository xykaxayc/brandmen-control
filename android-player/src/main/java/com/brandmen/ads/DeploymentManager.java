package com.brandmen.ads;

import android.content.Context;
import android.content.SharedPreferences;
import android.provider.Settings;
import android.os.StatFs;
import org.json.JSONArray;
import org.json.JSONObject;

import java.io.*;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * Хранилище протокола deployment v2.
 *
 * Ролики сохраняются как content-addressed blobs, manifest сначала попадает в
 * staging и становится активным только после полной проверки. Переключение
 * выполняется заменой маленького active.json; previous.json оставляет точку
 * отката. Legacy-каталог /sdcard/Movies/ads остаётся нетронутым.
 */
final class DeploymentManager {
    static final int PROTOCOL_VERSION = 2;
    private static final String CODEC_PROFILE = "h264-baseline-3.1-v4";
    private static final String PREFS = "brandmen_identity";
    private static final String KEY_DEVICE_ID = "device_id";
    private static final String KEY_API_TOKEN = "api_token";
    private static final int MAX_MANIFEST_BYTES = 1024 * 1024;

    private final Context app;
    private final File root;
    private final File blobs;
    private final File deployments;
    private final File staging;
    private final File state;
    private static final AtomicInteger ACTIVE_MUTATIONS = new AtomicInteger();

    DeploymentManager(Context context) {
        app = context.getApplicationContext();
        root = new File("/sdcard/Movies/brandmen-v2");
        blobs = new File(root, "blobs");
        deployments = new File(root, "deployments");
        staging = new File(root, "staging");
        state = new File(root, "state");
        blobs.mkdirs();
        deployments.mkdirs();
        staging.mkdirs();
        state.mkdirs();
    }

    String deviceId() {
        SharedPreferences sp = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        String id = sp.getString(KEY_DEVICE_ID, "");
        if (id == null || id.isEmpty()) {
            String androidId = null;
            try {
                androidId = Settings.Secure.getString(
                        app.getContentResolver(), Settings.Secure.ANDROID_ID);
            } catch (Exception ignored) {}
            id = androidId == null || androidId.isEmpty()
                    ? "tab-" + UUID.randomUUID()
                    : "tab-" + androidId;
            sp.edit().putString(KEY_DEVICE_ID, id).commit();
        }
        return id;
    }

    String apiToken() {
        SharedPreferences sp = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        String token = sp.getString(KEY_API_TOKEN, "");
        if (token == null || token.isEmpty()) {
            byte[] bytes = new byte[32];
            new SecureRandom().nextBytes(bytes);
            StringBuilder out = new StringBuilder();
            for (byte b : bytes) out.append(String.format(Locale.US, "%02x", b));
            token = out.toString();
            sp.edit().putString(KEY_API_TOKEN, token).commit();
        }
        return token;
    }

    boolean authorized(String authorization) {
        String expected = "Bearer " + apiToken();
        if (authorization == null || authorization.length() != expected.length()) {
            return false;
        }
        int diff = 0;
        for (int i = 0; i < expected.length(); i++) {
            diff |= expected.charAt(i) ^ authorization.charAt(i);
        }
        return diff == 0;
    }

    boolean isOperationActive() {
        return ACTIVE_MUTATIONS.get() > 0;
    }

    JSONObject capabilities() throws Exception {
        JSONObject caps = new JSONObject();
        caps.put("protocol_version", PROTOCOL_VERSION);
        caps.put("device_id", deviceId());
        caps.put("sha256", true);
        caps.put("resume", true);
        caps.put("atomic_commit", true);
        caps.put("rollback", true);
        caps.put("auth_required", true);
        return caps;
    }

    synchronized JSONObject prepare(String rawManifest) throws Exception {
        ACTIVE_MUTATIONS.incrementAndGet();
        try {
            if (rawManifest == null || rawManifest.length() == 0
                    || rawManifest.getBytes("UTF-8").length > MAX_MANIFEST_BYTES) {
                throw new IllegalArgumentException("invalid_manifest_size");
            }
            JSONObject manifest = new JSONObject(rawManifest);
            validateManifest(manifest);
            ensureSpace(manifest);
            String id = manifest.getString("deployment_id");
            atomicWrite(new File(staging, id + ".json"), manifest.toString().getBytes("UTF-8"));
            return statusFor(manifest);
        } finally {
            ACTIVE_MUTATIONS.decrementAndGet();
        }
    }

    synchronized JSONObject status(String deploymentId) throws Exception {
        JSONObject out = baseStatus();
        if (isHash(deploymentId)) {
            File manifestFile = stagedOrCommittedManifest(deploymentId);
            if (manifestFile.exists()) {
                JSONObject manifest = new JSONObject(readUtf8(manifestFile));
                JSONObject deploymentStatus = statusFor(manifest);
                out.put("deployment", deploymentStatus);
            }
        }
        return out;
    }

    synchronized JSONObject uploadBlob(String hash, long offset, long total,
                                       int contentLength, InputStream in) throws Exception {
        ACTIVE_MUTATIONS.incrementAndGet();
        try {
            if (!isHash(hash) || offset < 0 || total <= 0 || contentLength <= 0
                    || offset + contentLength > total) {
                throw new IllegalArgumentException("invalid_blob_request");
            }
            File complete = blobFile(hash);
            if (complete.exists()) {
                if (complete.length() == total && hash.equals(sha256(complete))) {
                    return blobResult(hash, complete.length(), total, true);
                }
                if (!complete.delete()) throw new IOException("cannot_remove_invalid_blob");
            }

            File part = new File(staging, hash + ".part");
            long current = part.exists() ? part.length() : 0;
            if (current != offset) {
                JSONObject conflict = blobResult(hash, current, total, false);
                conflict.put("error", "offset_mismatch");
                return conflict;
            }

            int remaining = contentLength;
            try (FileOutputStream fos = new FileOutputStream(part, offset > 0)) {
                byte[] buffer = new byte[65536];
                while (remaining > 0) {
                    int n = in.read(buffer, 0, Math.min(buffer.length, remaining));
                    if (n < 0) break;
                    fos.write(buffer, 0, n);
                    remaining -= n;
                }
                fos.flush();
                fos.getFD().sync();
            }
            if (remaining != 0 || part.length() != offset + contentLength) {
                throw new EOFException("incomplete_blob_upload");
            }

            if (part.length() < total) {
                return blobResult(hash, part.length(), total, false);
            }
            if (part.length() != total || !hash.equals(sha256(part))) {
                part.delete();
                throw new SecurityException("sha256_mismatch");
            }
            if (!part.renameTo(complete)) throw new IOException("cannot_publish_blob");
            return blobResult(hash, complete.length(), total, true);
        } finally {
            ACTIVE_MUTATIONS.decrementAndGet();
        }
    }

    synchronized JSONObject commit(String deploymentId) throws Exception {
        ACTIVE_MUTATIONS.incrementAndGet();
        try {
            if (!isHash(deploymentId)) throw new IllegalArgumentException("invalid_deployment_id");
            File staged = new File(staging, deploymentId + ".json");
            File committed = new File(deployments, deploymentId + ".json");
            File source = staged.exists() ? staged : committed;
            if (!source.exists()) throw new FileNotFoundException("manifest_not_prepared");
            JSONObject manifest = new JSONObject(readUtf8(source));
            validateManifest(manifest);
            JSONObject readiness = statusFor(manifest);
            if (readiness.getJSONArray("missing").length() != 0) {
                throw new IllegalStateException("deployment_not_ready");
            }

            if (!committed.exists()) atomicWrite(committed, manifest.toString().getBytes("UTF-8"));
            String current = activeDeploymentId();
            if (!current.isEmpty() && !current.equals(deploymentId)) {
                writePointer("previous.json", current);
            }
            writePointer("active.json", deploymentId);
            if (staged.exists()) staged.delete();
            garbageCollect();

            JSONObject result = baseStatus();
            result.put("ok", true);
            result.put("active_deployment_id", deploymentId);
            return result;
        } finally {
            ACTIVE_MUTATIONS.decrementAndGet();
        }
    }

    synchronized JSONObject rollback() throws Exception {
        ACTIVE_MUTATIONS.incrementAndGet();
        try {
            String previous = pointer("previous.json");
            if (!isHash(previous) || !new File(deployments, previous + ".json").exists()) {
                throw new IllegalStateException("no_previous_deployment");
            }
            String current = activeDeploymentId();
            writePointer("active.json", previous);
            if (isHash(current)) writePointer("previous.json", current);
            JSONObject result = baseStatus();
            result.put("ok", true);
            result.put("active_deployment_id", previous);
            return result;
        } finally {
            ACTIVE_MUTATIONS.decrementAndGet();
        }
    }

    String activeDeploymentId() {
        return pointer("active.json");
    }

    String activePlaylistHash() {
        try {
            JSONObject manifest = activeManifest();
            return manifest == null ? "" : manifest.optString("playlist_hash", "");
        } catch (Exception e) {
            return "";
        }
    }

    List<File> activeFiles() {
        List<File> result = new ArrayList<>();
        try {
            JSONObject manifest = activeManifest();
            if (manifest == null) return result;
            Map<String, String> byName = hashesByName(manifest);
            JSONArray playlist = manifest.getJSONArray("playlist");
            for (int i = 0; i < playlist.length(); i++) {
                String name = playlist.getString(i);
                String hash = byName.get(name);
                if (hash == null) continue;
                File file = blobFile(hash);
                if (file.exists() && !result.contains(file)) result.add(file);
            }
        } catch (Exception e) {
            android.util.Log.w("Deployment", "activeFiles: " + e.getMessage());
        }
        return result;
    }

    String hashForActiveLogicalName(String logicalName) {
        try {
            JSONObject manifest = activeManifest();
            if (manifest == null) return "";
            String hash = hashesByName(manifest).get(logicalName);
            return hash == null ? "" : hash;
        } catch (Exception e) {
            return "";
        }
    }

    String logicalNameForBlob(File blob) {
        try {
            JSONObject manifest = activeManifest();
            if (manifest == null) return blob.getName();
            JSONArray files = manifest.getJSONArray("files");
            for (int i = 0; i < files.length(); i++) {
                JSONObject f = files.getJSONObject(i);
                if (blob.getName().equals(f.getString("sha256") + ".mp4")) {
                    return f.getString("logical_name");
                }
            }
        } catch (Exception ignored) {}
        return blob.getName();
    }

    private JSONObject activeManifest() throws Exception {
        String id = activeDeploymentId();
        if (!isHash(id)) return null;
        File file = new File(deployments, id + ".json");
        return file.exists() ? new JSONObject(readUtf8(file)) : null;
    }

    private JSONObject baseStatus() throws Exception {
        JSONObject out = capabilities();
        out.put("active_deployment_id", activeDeploymentId());
        out.put("previous_deployment_id", pointer("previous.json"));
        out.put("playlist_hash", activePlaylistHash());
        return out;
    }

    private JSONObject statusFor(JSONObject manifest) throws Exception {
        JSONArray missing = new JSONArray();
        JSONObject partial = new JSONObject();
        JSONArray files = manifest.getJSONArray("files");
        for (int i = 0; i < files.length(); i++) {
            JSONObject file = files.getJSONObject(i);
            String hash = file.getString("sha256");
            long size = file.getLong("size");
            File blob = blobFile(hash);
            if (blob.exists() && blob.length() == size) {
                if (hash.equals(sha256(blob))) continue;
                blob.delete();
            }
            missing.put(hash);
            File part = new File(staging, hash + ".part");
            if (part.exists()) partial.put(hash, part.length());
        }
        JSONObject out = new JSONObject();
        out.put("deployment_id", manifest.getString("deployment_id"));
        out.put("missing", missing);
        out.put("partial", partial);
        out.put("ready", missing.length() == 0);
        return out;
    }

    private JSONObject blobResult(String hash, long received, long total, boolean complete)
            throws Exception {
        JSONObject out = new JSONObject();
        out.put("sha256", hash);
        out.put("received", received);
        out.put("total", total);
        out.put("complete", complete);
        return out;
    }

    private File stagedOrCommittedManifest(String id) {
        File staged = new File(staging, id + ".json");
        return staged.exists() ? staged : new File(deployments, id + ".json");
    }

    private File blobFile(String hash) {
        return new File(blobs, hash + ".mp4");
    }

    private void validateManifest(JSONObject manifest) throws Exception {
        if (manifest.getInt("protocol_version") != PROTOCOL_VERSION) {
            throw new IllegalArgumentException("unsupported_protocol");
        }
        if (!CODEC_PROFILE.equals(manifest.getString("codec_profile"))) {
            throw new IllegalArgumentException("unsupported_codec_profile");
        }
        String id = manifest.getString("deployment_id");
        if (!isHash(id) || !isHash(manifest.getString("playlist_hash"))) {
            throw new IllegalArgumentException("invalid_manifest_hash");
        }
        JSONArray files = manifest.getJSONArray("files");
        if (files.length() == 0) throw new IllegalArgumentException("empty_deployment");
        Set<String> names = new HashSet<>();
        for (int i = 0; i < files.length(); i++) {
            JSONObject file = files.getJSONObject(i);
            String name = file.getString("logical_name");
            String hash = file.getString("sha256");
            long size = file.getLong("size");
            if (!safeName(name) || !isHash(hash) || size <= 0 || !names.add(name)) {
                throw new IllegalArgumentException("invalid_manifest_file");
            }
        }
        JSONArray playlist = manifest.getJSONArray("playlist");
        if (playlist.length() == 0) throw new IllegalArgumentException("empty_playlist");
        for (int i = 0; i < playlist.length(); i++) {
            if (!names.contains(playlist.getString(i))) {
                throw new IllegalArgumentException("playlist_file_missing");
            }
        }
        StringBuilder playlistCanonical = new StringBuilder();
        for (int i = 0; i < playlist.length(); i++) {
            if (i > 0) playlistCanonical.append('\n');
            playlistCanonical.append(playlist.getString(i));
        }
        if (!manifest.getString("playlist_hash")
                .equals(sha256Text(playlistCanonical.toString()))) {
            throw new SecurityException("playlist_hash_mismatch");
        }
        if (!id.equals(sha256Text(canonicalIdentity(manifest)))) {
            throw new SecurityException("deployment_id_mismatch");
        }
    }

    private String canonicalIdentity(JSONObject manifest) throws Exception {
        StringBuilder out = new StringBuilder();
        out.append("{\"protocol_version\":").append(PROTOCOL_VERSION)
                .append(",\"codec_profile\":")
                .append(JSONObject.quote(manifest.getString("codec_profile")))
                .append(",\"files\":[");
        JSONArray files = manifest.getJSONArray("files");
        for (int i = 0; i < files.length(); i++) {
            if (i > 0) out.append(',');
            JSONObject file = files.getJSONObject(i);
            out.append("{\"logical_name\":")
                    .append(JSONObject.quote(file.getString("logical_name")))
                    .append(",\"sha256\":")
                    .append(JSONObject.quote(file.getString("sha256")))
                    .append(",\"size\":").append(file.getLong("size"))
                    .append(",\"codec_profile\":")
                    .append(JSONObject.quote(file.getString("codec_profile")))
                    .append('}');
        }
        out.append("],\"playlist\":[");
        JSONArray playlist = manifest.getJSONArray("playlist");
        for (int i = 0; i < playlist.length(); i++) {
            if (i > 0) out.append(',');
            out.append(JSONObject.quote(playlist.getString(i)));
        }
        out.append("],\"playlist_hash\":")
                .append(JSONObject.quote(manifest.getString("playlist_hash")))
                .append('}');
        return out.toString();
    }

    private String sha256Text(String value) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        byte[] bytes = digest.digest(value.getBytes("UTF-8"));
        StringBuilder out = new StringBuilder();
        for (byte b : bytes) out.append(String.format(Locale.US, "%02x", b));
        return out.toString();
    }

    private void ensureSpace(JSONObject manifest) throws Exception {
        long required = 0;
        JSONArray files = manifest.getJSONArray("files");
        for (int i = 0; i < files.length(); i++) {
            JSONObject file = files.getJSONObject(i);
            String hash = file.getString("sha256");
            long total = file.getLong("size");
            File complete = blobFile(hash);
            if (complete.exists() && complete.length() == total
                    && hash.equals(sha256(complete))) continue;
            if (complete.exists()) complete.delete();
            File part = new File(staging, hash + ".part");
            required += Math.max(0, total - (part.exists() ? part.length() : 0));
        }
        long free = new StatFs(root.getAbsolutePath()).getAvailableBytes();
        long reserve = 50L * 1024L * 1024L;
        if (free < required + reserve) {
            throw new IllegalStateException("insufficient_space");
        }
    }

    /** Оставляет blobs только для active, previous и незавершённых staging. */
    private void garbageCollect() {
        try {
            Set<String> keepDeployments = new HashSet<>();
            String active = activeDeploymentId();
            String previous = pointer("previous.json");
            if (isHash(active)) keepDeployments.add(active);
            if (isHash(previous)) keepDeployments.add(previous);

            File[] stagedManifests = staging.listFiles(
                    (dir, name) -> name.endsWith(".json"));
            Set<String> referenced = new HashSet<>();
            for (String id : keepDeployments) {
                collectHashes(new File(deployments, id + ".json"), referenced);
            }
            if (stagedManifests != null) {
                for (File file : stagedManifests) collectHashes(file, referenced);
            }

            File[] manifests = deployments.listFiles(
                    (dir, name) -> name.endsWith(".json"));
            if (manifests != null) {
                for (File file : manifests) {
                    String name = file.getName();
                    String id = name.substring(0, name.length() - 5);
                    if (!keepDeployments.contains(id)) file.delete();
                }
            }
            File[] blobFiles = blobs.listFiles();
            if (blobFiles != null) {
                for (File file : blobFiles) {
                    String name = file.getName();
                    String hash = name.endsWith(".mp4")
                            ? name.substring(0, name.length() - 4) : name;
                    if (!referenced.contains(hash)) file.delete();
                }
            }
        } catch (Exception e) {
            android.util.Log.w("Deployment", "garbageCollect: " + e.getMessage());
        }
    }

    private void collectHashes(File manifestFile, Set<String> target) {
        try {
            if (!manifestFile.exists()) return;
            JSONArray files =
                    new JSONObject(readUtf8(manifestFile)).getJSONArray("files");
            for (int i = 0; i < files.length(); i++) {
                target.add(files.getJSONObject(i).getString("sha256"));
            }
        } catch (Exception ignored) {}
    }

    private Map<String, String> hashesByName(JSONObject manifest) throws Exception {
        Map<String, String> out = new HashMap<>();
        JSONArray files = manifest.getJSONArray("files");
        for (int i = 0; i < files.length(); i++) {
            JSONObject file = files.getJSONObject(i);
            out.put(file.getString("logical_name"), file.getString("sha256"));
        }
        return out;
    }

    private boolean safeName(String name) {
        return name != null && !name.isEmpty() && !name.contains("/")
                && !name.contains("\\") && !name.contains("..");
    }

    private boolean isHash(String value) {
        return value != null && value.matches("[0-9a-f]{64}");
    }

    private String pointer(String name) {
        try {
            File file = new File(state, name);
            if (!file.exists()) return "";
            return new JSONObject(readUtf8(file)).optString("deployment_id", "");
        } catch (Exception e) {
            return "";
        }
    }

    private void writePointer(String name, String deploymentId) throws Exception {
        JSONObject value = new JSONObject();
        value.put("deployment_id", deploymentId);
        atomicWrite(new File(state, name), value.toString().getBytes("UTF-8"));
    }

    private void atomicWrite(File target, byte[] data) throws Exception {
        target.getParentFile().mkdirs();
        File tmp = new File(target.getPath() + ".tmp");
        try (FileOutputStream out = new FileOutputStream(tmp)) {
            out.write(data);
            out.flush();
            out.getFD().sync();
        }
        File old = new File(target.getPath() + ".old");
        if (old.exists()) old.delete();
        boolean existed = target.exists();
        if (existed && !target.renameTo(old)) {
            tmp.delete();
            throw new IOException("cannot_backup_state");
        }
        if (!tmp.renameTo(target)) {
            if (existed) old.renameTo(target);
            throw new IOException("cannot_commit_state");
        }
        if (old.exists()) old.delete();
    }

    private String readUtf8(File file) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (FileInputStream in = new FileInputStream(file)) {
            byte[] buffer = new byte[8192];
            int n;
            while ((n = in.read(buffer)) != -1) out.write(buffer, 0, n);
        }
        return out.toString("UTF-8");
    }

    private String sha256(File file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (FileInputStream in = new FileInputStream(file)) {
            byte[] buffer = new byte[65536];
            int n;
            while ((n = in.read(buffer)) != -1) digest.update(buffer, 0, n);
        }
        StringBuilder out = new StringBuilder();
        for (byte b : digest.digest()) out.append(String.format(Locale.US, "%02x", b));
        return out.toString();
    }
}
