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
