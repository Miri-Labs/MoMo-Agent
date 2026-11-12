# Keep Kotlin serialization metadata for the wire models.
-keepclassmembers class com.momoagent.android.data.** {
    *** Companion;
}
-keepclasseswithmembers class com.momoagent.android.data.** {
    kotlinx.serialization.KSerializer serializer(...);
}
