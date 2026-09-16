package com.wym.c2;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.os.Build;
import android.os.IBinder;

public class AgentService extends Service {

    private static final String CHANNEL = "wym";
    private static final int NOTIF_ID = 1;
    private Thread thread;
    private WymAgent agent;

    @Override
    public void onCreate() {
        super.onCreate();
        NotificationManager nm = getSystemService(NotificationManager.class);
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(new NotificationChannel(CHANNEL, "agent", NotificationManager.IMPORTANCE_MIN));
        }
        Notification n = new Notification.Builder(this, CHANNEL)
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setContentTitle(getString(R.string.app_name))
                .setContentText("heartbeat service")
                .setOngoing(true)
                .build();
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIF_ID, n, android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        } else {
            startForeground(NOTIF_ID, n);
        }
        start();
    }

    private void start() {
        if (agent != null) {
            return;
        }
        agent = new WymAgent(this, new Runnable() {
            @Override
            public void run() {
                stopSelf();
            }
        });
        thread = new Thread(agent, "wym-agent");
        thread.start();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        start();
        return START_STICKY;
    }

    @Override
    public void onDestroy() {
        if (agent != null) {
            agent.stop();
        }
        if (thread != null) {
            thread.interrupt();
        }
        agent = null;
        thread = null;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}