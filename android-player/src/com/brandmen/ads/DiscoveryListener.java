package com.brandmen.ads;

import android.util.Log;
import org.json.JSONObject;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;

/**
 * Listens for UDP broadcast packets from Brandmen Control (port 5012).
 * Calls onFound(ip) on the first valid packet, then stops.
 */
public class DiscoveryListener {
    public interface Callback {
        void onFound(String ip);
        void onTimeout();
    }

    public static final int PORT = 5012;
    private static final int TIMEOUT_MS = 10_000;

    private volatile boolean cancelled;

    public void findAsync(Callback cb) {
        cancelled = false;
        Thread t = new Thread(() -> {
            try (DatagramSocket socket = new DatagramSocket(PORT)) {
                socket.setSoTimeout(TIMEOUT_MS);
                byte[] buf = new byte[512];
                DatagramPacket packet = new DatagramPacket(buf, buf.length);
                socket.receive(packet);
                if (cancelled) return;

                String body = new String(packet.getData(), 0, packet.getLength(), "UTF-8");
                JSONObject json = new JSONObject(body);
                if ("brandmen-control".equals(json.optString("service"))) {
                    String ip = packet.getAddress().getHostAddress();
                    cb.onFound(ip);
                } else {
                    cb.onTimeout();
                }
            } catch (java.net.SocketTimeoutException e) {
                if (!cancelled) cb.onTimeout();
            } catch (Exception e) {
                Log.w("Discovery", "error: " + e.getMessage());
                if (!cancelled) cb.onTimeout();
            }
        }, "DiscoveryListener");
        t.setDaemon(true);
        t.start();
    }

    public void cancel() {
        cancelled = true;
    }
}
