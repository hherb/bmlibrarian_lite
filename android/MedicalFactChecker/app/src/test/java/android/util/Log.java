/*
 * Shadow of android.util.Log for unit tests.
 *
 * The Android framework's Log class is not available in JVM unit tests.
 * This no-op implementation allows code that uses android.util.Log to
 * run without Robolectric or an Android emulator.
 */
package android.util;

public class Log {
    public static int d(String tag, String msg) { return 0; }
    public static int i(String tag, String msg) { return 0; }
    public static int w(String tag, String msg) { return 0; }
    public static int e(String tag, String msg) { return 0; }
    public static int v(String tag, String msg) { return 0; }
}
