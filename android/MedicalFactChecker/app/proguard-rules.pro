# proguard-rules.pro
# MedicalFactChecker Android App - ProGuard Rules

# Keep Retrofit interfaces
-keep,allowobfuscation interface * {
    @retrofit2.http.* <methods>;
}

# Keep Kotlin Serialization classes
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.AnnotationsKt

-keepclassmembers class kotlinx.serialization.json.** {
    *** Companion;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Keep data classes used with Kotlin Serialization
-keep,includedescriptorclasses class com.bmlibrarian.factchecker.data.remote.**$$serializer { *; }
-keepclassmembers class com.bmlibrarian.factchecker.data.remote.** {
    *** Companion;
}
-keepclasseswithmembers class com.bmlibrarian.factchecker.data.remote.** {
    kotlinx.serialization.KSerializer serializer(...);
}

-keep,includedescriptorclasses class com.bmlibrarian.factchecker.domain.model.**$$serializer { *; }
-keepclassmembers class com.bmlibrarian.factchecker.domain.model.** {
    *** Companion;
}
-keepclasseswithmembers class com.bmlibrarian.factchecker.domain.model.** {
    kotlinx.serialization.KSerializer serializer(...);
}

# Room
-keep class * extends androidx.room.RoomDatabase
-keep @androidx.room.Entity class *

# Coroutines
-keepnames class kotlinx.coroutines.internal.MainDispatcherFactory {}
-keepnames class kotlinx.coroutines.CoroutineExceptionHandler {}

# Hilt
-keep class dagger.hilt.** { *; }
-keep class javax.inject.** { *; }
-keep class * extends dagger.hilt.android.internal.managers.ComponentSupplier { *; }
-keep class * extends dagger.hilt.android.internal.managers.ViewComponentManager$FragmentContextWrapper { *; }

# Keep enum classes
-keepclassmembers enum * {
    public static **[] values();
    public static ** valueOf(java.lang.String);
}

# SPIKE (WP-2): JNA binds the UniFFI bindings' native methods by reflection, and
# JNA itself is reached from native code, so R8 must neither strip nor rename
# either. Without these a release build fails at the first call into Rust.
-keep class com.sun.jna.** { *; }
-keep class * implements com.sun.jna.** { *; }
-keep class org.bmlib.ffi.** { *; }
-dontwarn java.awt.**

# Annotation-processor code (AutoValue's shaded javapoet) on the runtime classpath; never loaded
-dontwarn javax.lang.model.**
-dontwarn autovalue.shaded.**
# Markwon's HTML StrikeHandler probes for this with Class.forName and falls back to StrikethroughSpan
-dontwarn org.commonmark.ext.gfm.strikethrough.**
# iText's slf4j-api falls back to NOP when no binding is present
-dontwarn org.slf4j.impl.StaticLoggerBinder

# Retrofit 2.9 suspend funs: R8 full mode strips the generic Signature of Response, so the call fails "Response must include generic type"
-keep,allowobfuscation,allowshrinking class retrofit2.Response
-keep,allowobfuscation,allowshrinking class kotlin.coroutines.Continuation
