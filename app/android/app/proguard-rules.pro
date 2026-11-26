# R8/ProGuard keep 규칙. Flutter 엔진·플러그인 대부분은 consumer 규칙을 자체 포함한다. 아래는 안전망.
# Kotlin·Gradle·R8은 로컬에서 검증하지 못한다. CI(app.yml)의 릴리스 빌드와 실기기에서 확인한다.

# Flutter
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.embedding.** { *; }
-dontwarn io.flutter.embedding.**
# Play Core(deferred components)는 쓰지 않는다. Flutter 엔진이 참조만 한다.
-dontwarn com.google.android.play.core.**

# 앱 MethodChannel 구현(MainActivity)
-keep class com.fitlog.fitlog.** { *; }

# Play Integrity
-keep class com.google.android.play.core.integrity.** { *; }
-keep class com.google.android.play.integrity.** { *; }

# flutter_local_notifications: Gson으로 예약 알림을 (역)직렬화하고 receiver를 매니페스트로 참조한다.
-keep class com.dexterous.** { *; }
-keep class * extends com.google.gson.TypeAdapter
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer
-keepattributes Signature
-keepattributes *Annotation*

# drift / sqlite3(네이티브 라이브러리 JNI 바인딩)
-keep class eu.simonbinder.sqlite3_flutter_libs.** { *; }
-keep class org.sqlite.** { *; }
-keep class androidx.sqlite.** { *; }
-keepclasseswithmembernames class * { native <methods>; }

# Sentry(sentry_flutter가 consumer 규칙을 포함하지만 난독화 매핑·네이티브 SDK 보호용)
-keep class io.sentry.** { *; }
-dontwarn io.sentry.**
-keepattributes LineNumberTable,SourceFile
-renamesourcefileattribute SourceFile

# Google Sign-In / Credential Manager
-keep class com.google.android.libraries.identity.googleid.** { *; }
-dontwarn androidx.credentials.**

# flutter_secure_storage
-keep class com.it_nomads.fluttersecurestorage.** { *; }
-dontwarn com.google.errorprone.annotations.**
-dontwarn javax.annotation.**
