# Flutter tự nạp file này khi build release (R8).
#
# ML Kit tự tìm các thành phần của nó lúc chạy (qua reflection, ví dụ VisionCommonRegistrar).
# R8 không thấy chỗ dùng nên xoá/đổi tên chúng -> mọi khung hình camera báo
# "ImageError: Getting Image failed ... NullPointerException ... getClass() on a null object"
# và màn quét không bao giờ thấy khuôn mặt. Giữ nguyên ML Kit và plugin Flutter của nó.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_** { *; }
-keep class com.google_mlkit_commons.** { *; }
-keep class com.google_mlkit_face_detection.** { *; }

# tflite_flutter gọi thư viện TensorFlow Lite native; giữ các lớp Java/JNI của nó.
-keep class org.tensorflow.** { *; }
-dontwarn org.tensorflow.**
