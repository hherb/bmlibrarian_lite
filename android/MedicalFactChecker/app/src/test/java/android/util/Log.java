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

    /** Forget every line recorded so far. */
    public static void clear() { lines.clear(); }

    public static int d(String tag, String msg) { return record(tag, msg); }
    public static int i(String tag, String msg) { return record(tag, msg); }
    public static int w(String tag, String msg) { return record(tag, msg); }
    public static int e(String tag, String msg) { return record(tag, msg); }
    public static int v(String tag, String msg) { return record(tag, msg); }

    private static int record(String tag, String msg) {
        lines.add(tag + ": " + msg);
        return 0;
    }
}
