# Keep the WebView JS bridge — it is called BY NAME from injected JavaScript, so R8 has no way to
# see the reference. Renaming or removing it silently breaks every Lightning Bolt read.
-keepclassmembers class com.nvdberg.workingbolt.data.LBWebSource$Bridge {
    public *;
}
-keepattributes JavascriptInterface
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}

# kotlinx.serialization — the plugin ships consumer rules, but the disk-cache path (Store.kt) is only
# exercised after a real sign-in, so keep the generated serializers explicitly rather than find out
# on someone's phone that a cached roster won't decode.
-keepattributes *Annotation*, InnerClasses
-dontnote kotlinx.serialization.**
-keepclassmembers class com.nvdberg.workingbolt.** {
    *** Companion;
}
-keepclasseswithmembers class com.nvdberg.workingbolt.** {
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class com.nvdberg.workingbolt.**$$serializer { *; }
