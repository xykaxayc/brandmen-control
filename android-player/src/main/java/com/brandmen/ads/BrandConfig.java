package com.brandmen.ads;

import android.content.Context;
import org.json.JSONObject;

/** Бренд-пакет, полученный от пульта. Хранится на планшете и переживает ребут. */
final class BrandConfig {
    private static final String PREF = "brand_pack";
    static final String DEFAULT_NAME = "BRANDMEN";
    static final String DEFAULT_ACCENT = "#E0B85C";

    static void apply(Context ctx, String json) throws Exception {
        JSONObject j = new JSONObject(json);
        String name = j.optString("name", DEFAULT_NAME).trim();
        String mark = j.optString("mark", "B").trim();
        String accent = j.optString("accent", DEFAULT_ACCENT).trim();
        String tagline = j.optString("tagline", "Реклама на экране").trim();
        if (!accent.matches("#[0-9a-fA-F]{6}")) throw new IllegalArgumentException("bad accent");
        ctx.getSharedPreferences(PREF, Context.MODE_PRIVATE).edit()
                .putString("name", name.isEmpty() ? DEFAULT_NAME : name)
                .putString("mark", mark.isEmpty() ? "B" : mark)
                .putString("accent", accent).putString("tagline", tagline).apply();
        MainActivity a = MainActivity.peek();
        if (a != null) a.runOnUiThread(a::applyBranding);
    }

    static String name(Context c) { return c.getSharedPreferences(PREF, 0).getString("name", DEFAULT_NAME); }
    static String accent(Context c) { return c.getSharedPreferences(PREF, 0).getString("accent", DEFAULT_ACCENT); }
    static String tagline(Context c) { return c.getSharedPreferences(PREF, 0).getString("tagline", "Реклама на экране"); }
}
