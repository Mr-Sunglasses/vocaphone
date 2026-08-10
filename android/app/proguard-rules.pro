# sherpa-onnx's JNI reads every config value by field name through GetFieldID and
# builds OfflineRecognizerResult from native code, none of which R8 can see. The
# default native-method rule keeps these class names, because they appear in a
# native method descriptor, but not their fields: R8 renamed
# OfflineRecognizerConfig.decodingMethod to "d" and dropped the unread numeric
# fields, which the native side reports as "Failed to get field ID for
# decodingMethod" the moment a sherpa model loads. Debug builds are unaffected,
# so this only ever appears in a release build.
-keep class com.k2fsa.sherpa.onnx.** { *; }

# OkHttp ships optional platform integrations that are absent at runtime.
-dontwarn okhttp3.internal.platform.**
-dontwarn org.conscrypt.**
-dontwarn org.bouncycastle.**
-dontwarn org.openjsse.**
