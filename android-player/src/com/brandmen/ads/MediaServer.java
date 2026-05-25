package com.brandmen.ads;

import java.io.*;
import java.net.*;
import java.util.*;

/**
 * Minimal HTTP server (port 5011) for direct WiFi file transfer.
 * No external dependencies — pure Java sockets.
 *
 * Endpoints:
 *   GET  /version          — {"version":"0.42.0"}
 *   GET  /files            — JSON list of video files with sizes
 *   GET  /file/<name>      — download a file
 *   POST /upload/<name>    — upload a file (Content-Length required)
 *   DELETE /file/<name>    — delete a file
 *   GET  /ping             — {"ok":true}
 */
public class MediaServer {
    public static final int PORT = 5011;
    // Версия встраивается CI через sed при каждой сборке
    public static final String VERSION = "0.0.0";

    private final String mediaDir;
    private ServerSocket serverSocket;
    private Thread acceptThread;
    private volatile boolean running;

    public MediaServer(String mediaDir) {
        this.mediaDir = mediaDir;
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

            // Read request line
            String requestLine = readAsciiLine(in);
            if (requestLine == null || requestLine.isEmpty()) return;
            String[] parts = requestLine.split(" ");
            if (parts.length < 2) return;
            String method = parts[0].toUpperCase();
            String rawPath = parts[1];
            String path;
            try { path = URLDecoder.decode(rawPath, "UTF-8"); }
            catch (Exception e) { path = rawPath; }

            // Read headers
            long contentLength = -1;
            String line;
            while (!(line = readAsciiLine(in)).isEmpty()) {
                int colon = line.indexOf(':');
                if (colon > 0) {
                    String key = line.substring(0, colon).trim().toLowerCase(Locale.US);
                    String value = line.substring(colon + 1).trim();
                    if (key.equals("content-length")) {
                        try { contentLength = Long.parseLong(value); } catch (NumberFormatException ignored) {}
                    }
                }
            }

            // Route
            if (method.equals("GET") && path.equals("/ping")) {
                sendJson(out, 200, "{\"ok\":true}");
            } else if (method.equals("GET") && path.equals("/version")) {
                sendJson(out, 200, "{\"version\":\"" + VERSION + "\"}");
            } else if (method.equals("GET") && path.equals("/files")) {
                handleListFiles(out);
            } else if (method.equals("GET") && path.startsWith("/file/")) {
                handleGetFile(out, sanitize(path.substring(6)));
            } else if (method.equals("POST") && path.startsWith("/upload/")) {
                handleUpload(in, out, sanitize(path.substring(8)), contentLength);
            } else if (method.equals("DELETE") && path.startsWith("/file/")) {
                handleDelete(out, sanitize(path.substring(6)));
            } else {
                sendText(out, 404, "Not Found");
            }
            out.flush();
        } catch (Exception e) {
            android.util.Log.w("MediaServer", "handle: " + e.getMessage());
        }
    }

    // ---- Handlers ----

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
                              String filename, long contentLength) throws IOException {
        if (filename.isEmpty() || contentLength < 0) {
            sendText(out, 400, "Bad Request"); return;
        }
        File dest = new File(mediaDir, filename + ".part");
        new File(mediaDir).mkdirs();
        try (FileOutputStream fos = new FileOutputStream(dest)) {
            byte[] buf = new byte[65536];
            long remaining = contentLength;
            while (remaining > 0) {
                int toRead = (int) Math.min(buf.length, remaining);
                int n = in.read(buf, 0, toRead);
                if (n < 0) break;
                fos.write(buf, 0, n);
                remaining -= n;
            }
            if (remaining != 0) {
                dest.delete();
                sendText(out, 400, "Incomplete upload");
                return;
            }
        }
        File final_ = new File(mediaDir, filename);
        if (final_.exists()) final_.delete();
        if (!dest.renameTo(final_)) {
            dest.delete();
            sendText(out, 500, "Upload failed");
            return;
        }
        sendJson(out, 200, "{\"ok\":true,\"name\":\"" + escJson(filename) + "\"}");
    }

    private void handleDelete(OutputStream out, String filename) throws IOException {
        if (filename.isEmpty()) { sendText(out, 400, "Bad Request"); return; }
        File f = new File(mediaDir, filename);
        boolean ok = f.exists() && f.delete();
        sendJson(out, ok ? 200 : 404, "{\"ok\":" + ok + "}");
    }

    // ---- Helpers ----

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
            case 404: return "Not Found";
            default: return "Error";
        }
    }

    /** Read one ASCII line (up to \n), discarding \r. Returns "" on blank line. */
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

    /** Strip path separators — prevent directory traversal. */
    private static String sanitize(String name) {
        return new File(name).getName();
    }

    private static String escJson(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }
}
