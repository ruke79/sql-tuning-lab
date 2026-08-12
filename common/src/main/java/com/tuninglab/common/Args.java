package com.tuninglab.common;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * "command --key=value" 형태의 단순 CLI 인자 파서.
 * 예) java -jar tpch.jar load --db=postgres --sf=1 --dir=./data/tpch
 */
public class Args {

    private final String command;
    private final Map<String, String> options = new LinkedHashMap<>();

    public Args(String[] raw) {
        String cmd = null;
        for (String a : raw) {
            if (a.startsWith("--")) {
                int eq = a.indexOf('=');
                if (eq > 0) {
                    options.put(a.substring(2, eq), a.substring(eq + 1));
                } else {
                    options.put(a.substring(2), "true");
                }
            } else if (cmd == null) {
                cmd = a;
            }
        }
        this.command = cmd == null ? "help" : cmd;
    }

    public String command() { return command; }

    public String get(String key, String defaultValue) {
        return options.getOrDefault(key, defaultValue);
    }

    public int getInt(String key, int defaultValue) {
        String v = options.get(key);
        return v == null ? defaultValue : Integer.parseInt(v);
    }

    public double getDouble(String key, double defaultValue) {
        String v = options.get(key);
        return v == null ? defaultValue : Double.parseDouble(v);
    }

    public boolean getBool(String key, boolean defaultValue) {
        String v = options.get(key);
        return v == null ? defaultValue : Boolean.parseBoolean(v);
    }
}
