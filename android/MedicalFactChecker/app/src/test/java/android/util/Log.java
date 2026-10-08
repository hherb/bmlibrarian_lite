/*
 * Shadow of android.util.Log for unit tests.
 *
 * The Android framework's Log class is not available in JVM unit tests.
 * This implementation allows code that uses android.util.Log to run without
 * Robolectric or an Android emulator, and records every line it is given so a
 * test can check what would reach logcat: an answer body must never be logged,
 * since NCBI's can repeat the API key (#252).
 */
package android.util;

import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

public class Log {
    /** Every line logged since the last {@link #clear()}, as "tag: message". */
    public static final List<String> lines = new CopyOnWriteArrayList<>();

    /**
     * The same lines with their level, as "L/tag: message" (L one of V, D, I, W, E,
     * as logcat writes it), for a test that pins how loud a line is.
     */
    public static final List<String> levelledLines = new CopyOnWriteArrayList<>();

    /** Forget every line recorded so far. */
    public static void clear() {
        lines.clear();
        levelledLines.clear();
    }

    public static int d(String tag, String msg) { return record("D", tag, msg); }
    public static int i(String tag, String msg) { return record("I", tag, msg); }
    public static int w(String tag, String msg) { return record("W", tag, msg); }
    public static int e(String tag, String msg) { return record("E", tag, msg); }
    public static int e(String tag, String msg, Throwable tr) { return record("E", tag, msg + ": " + tr); }
    public static int w(String tag, String msg, Throwable tr) { return record("W", tag, msg + ": " + tr); }
    public static int v(String tag, String msg) { return record("V", tag, msg); }

    private static int record(String level, String tag, String msg) {
        levelledLines.add(level + "/" + tag + ": " + msg);
        return record(tag, msg);
    }

    private static int record(String tag, String msg) {
        lines.add(tag + ": " + msg);
        return 0;
    }
}
