# Kiến trúc ứng dụng khóa thông minh – Khoabaomat

Tài liệu thiết kế app **Flutter (Android + iOS)** điều khiển khóa thông minh qua **Bluetooth Low Energy (BLE)**.
Thiết kế dựa trên phần cứng đã đấu và test thật trong project này (ESP32 + RC522 + AS608 + bàn phím 4×4 + relay),
xem [SO_DO_NOI_DAY.md](SO_DO_NOI_DAY.md).

> **Code trong tài liệu chính là code đang chạy trong project** (11/10/2026), không phải ví dụ viết riêng:
> - `flutter analyze` không lỗi, không cảnh báo; 8/8 unit/widget test qua (Flutter 3.47.3, Dart 3.13.3).
> - Integration test chạy với **ESP32 thật qua Bluetooth** thành công.
> - Firmware `firmware/smart_lock` đạt 10/10 bài test BLE (quét, mở, chống phát lại, chống sửa gói…).
> - Build được APK Android và bản Windows.
>
> Phiên bản package lấy từ pub.dev cùng ngày.
>
> **Tiến độ:** giai đoạn 0 (test phần cứng) và **giai đoạn 1 (BLE + mở/khóa qua app)** đã xong, xem [mục 9](#9-lộ-trình-triển-khai).

## Mục lục

1. [Tổng quan hệ thống](#1-tổng-quan-hệ-thống)
2. [Kiến trúc và cấu trúc thư mục](#2-kiến-trúc-và-cấu-trúc-thư-mục)
3. [Package Flutter cần dùng](#3-package-flutter-cần-dùng)
4. [Giao thức BLE giữa app và khóa](#4-giao-thức-ble-giữa-app-và-khóa)
5. [Bảo mật](#5-bảo-mật)
6. [Code mẫu](#6-code-mẫu)
7. [Quy trình: quét khuôn mặt → mở khóa](#7-quy-trình-quét-khuôn-mặt--mở-khóa)
8. [Các tính năng phụ trợ trên phần cứng thật](#8-các-tính-năng-phụ-trợ-trên-phần-cứng-thật)
9. [Lộ trình triển khai](#9-lộ-trình-triển-khai)
10. [Kiểm thử](#10-kiểm-thử)

---

## 1. Tổng quan hệ thống

```
┌──────────────────── Điện thoại (Android / iOS) ────────────────────┐
│  App Flutter "Khoabaomat" – Material 3, sáng/tối                   │
│  • Xác thực người dùng: Face ID / vân tay (local_auth)             │
│                         hoặc FaceNet + nháy mắt (lấy từ faceid)    │
│  • Khóa AES-256 riêng của điện thoại: Keystore / Keychain          │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ BLE 4.2 · GATT service 8a1c0001-…
                               │ gói AES-256-GCM + nonce + bộ đếm
┌──────────────────────────────▼──────── ESP32-D0WD-V3 (WROOM) ──────┐
│  BLE server · kiểm tra lệnh · lưu khóa điện thoại, thẻ, PIN (NVS)  │
│  nhật ký ra vào (LittleFS) · đồng bộ giờ từ app                    │
└──┬────────────┬───────────────┬────────────┬───────────┬───────────┘
   │ SPI        │ UART2         │ ma trận    │           │
 RC522        AS608           Bàn phím 4×4  Relay       LED xanh 2 / đỏ 15
 SS5 SCK18    RX2=16          hàng 13,14,   GPIO22      Buzzer 12
 MISO19       TX2=17          27,26           │         Nút mở GPIO34
 MOSI23 RST4  300 mẫu         cột 25,33,      ▼
                              32,21         Chốt khóa 12V
```

**Mỗi tính năng xử lý ở đâu:**

| Tính năng | App (điện thoại) | Khóa (ESP32) | Phần cứng |
|---|---|---|---|
| Mở bằng khuôn mặt | Quét mặt, xác thực, ký lệnh | Kiểm tra lệnh, đóng relay | Camera trước của điện thoại, relay |
| Mở bằng vân tay điện thoại | Touch ID / BiometricPrompt | Như trên | Cảm biến vân tay của điện thoại |
| Mở bằng vân tay trên khóa | Quản lý danh sách (ai = ID nào) | So khớp trên AS608 | AS608 (UART2) |
| Mở bằng thẻ | Quản lý danh sách thẻ | So UID thẻ với danh sách | RC522 (SPI) |
| Mở bằng mã PIN | Đặt PIN, tạo mã khách (TOTP) | Kiểm tra mã gõ trên bàn phím | Bàn phím 4×4 |
| Nút mở từ trong nhà | – | Đọc nút, đóng relay | Nút GPIO34 |
| Ghép đôi điện thoại mới | Hiện mã 6 số | Vào chế độ ghép khi giữ nút; nhận mã gõ trên bàn phím | Nút GPIO34 + bàn phím |
| Nhật ký ra vào | Hiển thị, lưu đệm | Ghi mọi lần mở / thử sai | Flash ESP32 (LittleFS) |

### Ba loại "sinh trắc học" – không được nhầm

| Loại | Dữ liệu nằm ở đâu | App biết được gì | Dùng để |
|---|---|---|---|
| **Face ID / vân tay của điện thoại** (`local_auth`) | Chip bảo mật của điện thoại, không bao giờ ra ngoài | Chỉ biết đúng / sai, **không biết là ai** | Xác nhận người cầm máy là chủ máy |
| **FaceNet trong app** (lấy từ project `faceid`) | Vector 512 số do app lưu (flutter_secure_storage) | Biết **thành viên nào** đang quét | Điện thoại dùng chung cho nhiều người (vd. tablet gắn tường) |
| **Vân tay trên khóa** (AS608) | Bộ nhớ của cảm biến AS608 (ID 1–300) | App chỉ lưu ánh xạ ID → thành viên | Mở cửa không cần điện thoại |

**Đề xuất:**
- Mặc định dùng **`local_auth`**, chỉ nhận sinh trắc học loại *mạnh*.
- **FaceNet** là tùy chọn "Chế độ máy dùng chung". Chế độ này kém an toàn hơn Face ID (ảnh 2D vẫn có thể bị giả mạo dù đã kiểm tra nháy mắt), nên mặc định tắt.
- Trên Android, mở khóa bằng khuôn mặt của đa số máy chỉ là loại *weak* (camera 2D). `local_auth` với `biometricOnly: true` sẽ dùng vân tay thay thế. Đây là hành vi đúng, không phải lỗi.

---

## 2. Kiến trúc và cấu trúc thư mục

**Clean Architecture + Bloc**, chia theo tính năng (feature-first). Mỗi tính năng có 3 lớp, chỉ phụ thuộc theo chiều mũi tên:

```
presentation (Widget, Bloc)  ──►  domain (Entity, UseCase, Repository interface)  ◄──  data (Repository impl, DataSource)
                                          ▲
                                     core (BLE, crypto, lưu trữ, DI, theme, router)
```

- **domain** không import Flutter, BLE hay bất kỳ package lưu trữ nào. Vì vậy test được bằng `mocktail` mà không cần điện thoại.
- **data** là nơi duy nhất chạm vào `flutter_blue_plus`, `flutter_secure_storage`, `drift`.
- **presentation** chỉ nói chuyện với Bloc. Bloc gọi UseCase.
- Truyền phụ thuộc bằng `get_it` (tệp `core/di/injection.dart`).

### 2.1. Cây thư mục app

Ký hiệu ✅ = file có code đầy đủ trong [mục 6](#6-code-mẫu) (đã analyze + test).

```
Khoabaomat/
├── lib/
│   ├── main.dart                         # configureDependencies() → runApp(App)
│   ├── app.dart                          # MaterialApp.router, theme sáng/tối
│   ├── core/
│   │   ├── ble/
│   │   │   ├── lock_protocol.dart        ✅ UUID, loại gói, mã lệnh, mã kết quả
│   │   │   └── secure_command_sender.dart ✅ challenge → AES-GCM → gửi → kiểm tra (dùng cho mọi lệnh)
│   │   ├── crypto/
│   │   │   └── lock_crypto.dart          ✅ X25519 + HKDF (ghép đôi), AES-256-GCM (lệnh)
│   │   ├── storage/
│   │   │   ├── lock_key_store.dart       ✅ khóa AES + bộ đếm trong flutter_secure_storage
│   │   │   └── app_database.dart         # drift: thành viên, nhật ký đệm, thiết bị
│   │   ├── di/
│   │   │   └── injection.dart            ✅ đăng ký get_it
│   │   ├── dev/demo_pairing.dart         ✅ khóa demo của giai đoạn 1 (xóa ở giai đoạn 2)
│   │   ├── error/failures.dart           # Failure dùng chung cho domain
│   │   ├── router/app_router.dart        # go_router
│   │   └── theme/app_theme.dart          ✅ Material 3, ColorScheme.fromSeed, dark/light
│   └── features/
│       ├── device/                       # quét, kết nối, ghép đôi, đổi tên, trạng thái
│       │   ├── data/
│       │   │   ├── ble_lock_data_source.dart        ✅
│       │   │   └── lock_repository_impl.dart
│       │   ├── domain/
│       │   │   ├── lock_status.dart                     ✅ LockStatus + ReadLockStatus + LockNow
│       │   │   └── usecases/{pair_lock, rename_lock}.dart   (giai đoạn 2)
│       │   └── presentation/
│       │       ├── scan_cubit.dart, scan_page.dart      ✅ tìm khóa (lọc UUID, sắp theo RSSI)
│       │       ├── device_cubit.dart, device_page.dart  ✅ kết nối, trạng thái, mở, khóa ngay
│       │       └── pairing_page.dart                    (giai đoạn 2)
│       ├── biometric/
│       │   └── data/biometric_auth_service.dart     ✅ local_auth 3.x
│       ├── face/                         # chép từ faceid: lib/face/*, face_recognition_service.dart,
│       │   ├── data/                     #   face_scan_screen.dart, assets/models/facenet_512.tflite
│       │   ├── domain/usecases/identify_member_by_face.dart
│       │   └── presentation/face_scan_page.dart
│       ├── unlock/
│       │   ├── domain/unlock_with_biometric.dart    ✅
│       │   └── presentation/
│       │       ├── unlock_bloc.dart                 ✅
│       │       └── unlock_button.dart               ✅
│       ├── access/                       # PIN, mã khách TOTP, thẻ RFID, vân tay AS608
│       │   ├── data/ domain/ presentation/
│       ├── members/                      # thành viên, vai trò admin/member/guest, thu hồi
│       ├── logs/                         # đồng bộ & hiển thị nhật ký, lọc theo người/phương thức
│       └── settings/                     # theme, thời gian tự khóa, chế độ máy dùng chung
├── test/                                 ✅ unit + bloc + widget test (xem mục 10)
├── integration_test/ble_lock_test.dart   ✅ test với ESP32 thật qua Bluetooth
├── assets/models/facenet_512.tflite      # từ faceid (Apache-2.0)
└── firmware/                             # code ESP32 (Arduino)
```

### 2.2. Cây thư mục firmware

```
firmware/
├── smart_lock/                 # firmware chính – gộp dần qua các giai đoạn
│   ├── smart_lock.ino          ✅ giai đoạn 1: BLE server + AES-GCM + relay (mục 6.12)
│   ├── config.h                ✅ UUID, chân GPIO, mã lệnh/kết quả
│   ├── ble_service.cpp/.h      # tách từ smart_lock.ino khi file lớn dần
│   ├── protocol.cpp/.h         # tách gói, nonce, bộ đếm, phân quyền
│   ├── crypto.cpp/.h           # mbedtls: AES-GCM, X25519 (ECDH), HKDF
│   ├── storage.cpp/.h          # NVS (Preferences): điện thoại, thẻ, PIN băm; LittleFS: nhật ký
│   ├── access_rfid.cpp         # từ rfid_test.ino
│   ├── access_fingerprint.cpp  # từ fingerprint_test.ino
│   ├── access_keypad.cpp       # từ keypad_test.ino + PIN/TOTP
│   └── actuator.cpp            # relay, LED, buzzer, nút
├── rfid_test/                  ✅ đã test
├── keypad_test/                ✅ đã test
├── fingerprint_test/           ✅ đã test
└── fingerprint_diag/           ✅ công cụ chẩn đoán AS608
```

> Riêng phần BLE + mbedtls đã chiếm 85% phân vùng app mặc định (1,1 / 1,25 MB). Khi gộp đủ tính năng, bạn biên dịch với
> phân vùng **Huge APP (3 MB, không OTA)**:
> `arduino-cli compile --fqbn esp32:esp32:esp32:PartitionScheme=huge_app firmware/smart_lock`

### 2.3. Việc cần làm với project Khoabaomat hiện tại (✅ đã làm ở giai đoạn 1)

Project đang có 2 gói serial dùng cho bước test qua cáp USB. App thật dùng BLE nên cần:

1. **Bỏ** `usb_serial`, `serial_port_win32` và thư mục `packages/usb_serial`. Xóa thêm `intent-filter` `USB_DEVICE_ATTACHED` và file `res/xml/device_filter.xml` trong Android.
2. **Thêm iOS**: `flutter create --platforms ios .`. Lưu ý: muốn build và chạy trên iPhone phải có **máy Mac** cài Xcode.
3. **Android**:
   - `MainActivity` kế thừa `FlutterFragmentActivity`, vì `local_auth` bắt buộc.
   - `minSdk = 24`, vì `local_auth` 3.x yêu cầu.
   - Quyền trong `AndroidManifest.xml`:
     ```xml
     <uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />
     <uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
     <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
     <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
     <!-- Android 11 trở xuống: quét BLE cần quyền vị trí -->
     <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" android:maxSdkVersion="30" />
     <uses-permission android:name="android.permission.USE_BIOMETRIC" />
     <!-- CAMERA: thêm ở giai đoạn 5 (FaceNet) -->
     <uses-feature android:name="android.hardware.bluetooth_le" android:required="true" />
     ```
4. **iOS** (`ios/Runner/Info.plist`): thêm `NSBluetoothAlwaysUsageDescription`, `NSFaceIDUsageDescription`, `NSCameraUsageDescription`, mỗi khóa kèm câu giải thích bằng tiếng Việt.
5. **Sửa lỗi build trên máy này:**
   - `android/gradle.properties`: thêm `kotlin.incremental=false`. Project nằm ở ổ D: còn pub cache ở ổ C:, khiến Kotlin báo *"Could not close incremental caches"*. Project faceid đã gặp và xử lý lỗi này y như vậy.
   - `windows/CMakeLists.txt`: thêm `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS`. Visual Studio 2026 báo lỗi STL1011 với plugin `local_auth_windows`. Cờ này chỉ cần cho bản Windows dùng để test.

---

## 3. Package Flutter cần dùng

| Nhóm | Package | Phiên bản | Dùng để |
|---|---|---|---|
| BLE | [`flutter_blue_plus`](https://pub.dev/packages/flutter_blue_plus) | 2.3.14 | Quét, kết nối, GATT read/write/notify, MTU (Android, iOS, Windows). **Tự xin quyền** Bluetooth / vị trí khi quét |
| Sinh trắc học | [`local_auth`](https://pub.dev/packages/local_auth) | 3.0.2 | Face ID / Touch ID / Android BiometricPrompt |
| Nhận diện khuôn mặt (tùy chọn) | [`camera`](https://pub.dev/packages/camera) | 0.12.1 | Camera trước, luồng ảnh cho kiểm tra nháy mắt |
| | [`google_mlkit_face_detection`](https://pub.dev/packages/google_mlkit_face_detection) | 0.15.1 | Phát hiện mặt, vị trí mắt, xác suất mắt mở |
| | [`tflite_flutter`](https://pub.dev/packages/tflite_flutter) | 0.12.1 | Chạy FaceNet-512 trên máy |
| | [`image`](https://pub.dev/packages/image) | 4.10.1 | Xoay, căn thẳng, cắt khuôn mặt (bản đang dùng ổn định trong faceid) |
| Bảo mật | [`flutter_secure_storage`](https://pub.dev/packages/flutter_secure_storage) | 11.2.0 | Lưu khóa AES, bộ đếm, vector khuôn mặt (Keystore / Keychain) |
| | [`cryptography`](https://pub.dev/packages/cryptography) | 2.9.0 | AES-256-GCM, X25519, HKDF-SHA256 |
| | [`otp`](https://pub.dev/packages/otp) | 3.2.1 | Mã PIN khách theo thời gian (TOTP) |
| State, DI, điều hướng | [`flutter_bloc`](https://pub.dev/packages/flutter_bloc) | 9.1.1 | Bloc / Cubit |
| | [`equatable`](https://pub.dev/packages/equatable) | 3.0.0 | So sánh state/event |
| | [`get_it`](https://pub.dev/packages/get_it) | 9.3.0 | Service locator (DI) |
| | [`go_router`](https://pub.dev/packages/go_router) | 18.0.2 | Điều hướng, deep link |
| Dữ liệu trên máy | [`drift`](https://pub.dev/packages/drift) + [`drift_flutter`](https://pub.dev/packages/drift_flutter) | 2.35.2 / 0.3.1 | SQLite: thành viên, nhật ký đệm, thiết bị |
| | [`intl`](https://pub.dev/packages/intl) | 0.20.3 | Định dạng ngày giờ tiếng Việt trong nhật ký |
| Sinh code (tùy chọn) | [`freezed`](https://pub.dev/packages/freezed) / [`json_serializable`](https://pub.dev/packages/json_serializable) | 4.0.2 / 6.14.1 | Entity bất biến, JSON |
| Phát triển | [`drift_dev`](https://pub.dev/packages/drift_dev), [`build_runner`](https://pub.dev/packages/build_runner) | 2.35.1 / 2.16.2 | Sinh code drift / freezed |
| Kiểm thử | [`bloc_test`](https://pub.dev/packages/bloc_test), [`mocktail`](https://pub.dev/packages/mocktail) | 10.0.0 / 1.0.5 | Test Bloc, giả lập phụ thuộc |
| | [`flutter_lints`](https://pub.dev/packages/flutter_lints) | 6.0.0 | Luật `flutter analyze` |

```yaml
dependencies:
  flutter:
    sdk: flutter
  flutter_blue_plus: ^2.3.14
  local_auth: ^3.0.2
  flutter_secure_storage: ^11.2.0
  cryptography: ^2.9.0
  otp: ^3.2.1
  flutter_bloc: ^9.1.1
  equatable: ^3.0.0
  get_it: ^9.3.0
  go_router: ^18.0.2
  drift: ^2.35.2
  drift_flutter: ^0.3.1
  intl: ^0.20.3
  # Chế độ nhận diện khuôn mặt FaceNet (giống project faceid)
  camera: ^0.12.1
  google_mlkit_face_detection: ^0.15.1
  tflite_flutter: ^0.12.1
  image: ^4.10.1

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0
  bloc_test: ^10.0.0
  mocktail: ^1.0.5
  drift_dev: ^2.35.1
  build_runner: ^2.16.2
```

**Lưu ý về phiên bản:**
- **Không dùng `permission_handler`**. `flutter_blue_plus` đã tự xin quyền `BLUETOOTH_SCAN`/`BLUETOOTH_CONNECT` (Android 12+) và quyền vị trí (Android ≤ 11) khi quét. Ngoài ra, `permission_handler_android` 14.1.0 đòi `compileSdk 37` nhưng Gradle không nhận ra SDK `android-37.0` vừa cài, nên build lỗi.
- **`flutter_blue_plus` 2.x dùng giấy phép riêng** (FlutterBluePlus License), không còn BSD.
  - Lệnh `connect()` bắt buộc truyền tham số `license:`.
  - Dùng cá nhân, phi lợi nhuận hoặc ở trường học: `License.nonprofit`, miễn phí.
  - Dùng thương mại: `License.commercial`, phải trả phí. Nếu không muốn trả phí, thay bằng [`flutter_reactive_ble`](https://pub.dev/packages/flutter_reactive_ble) 5.6.0 (BSD). Chỉ cần viết lại `BleLockDataSource`, các lớp khác giữ nguyên.
- **`local_auth` 3.x đổi API** so với các bài hướng dẫn cũ (2.x):
  - Không còn `AuthenticationOptions`: `biometricOnly` và `persistAcrossBackgrounding` truyền thẳng vào `authenticate()`.
  - Lỗi được ném ra dưới dạng `LocalAuthException` với mã `LocalAuthExceptionCode`, không còn là `PlatformException`.

---

## 4. Giao thức BLE giữa app và khóa

### 4.1. GATT

| Thành phần | UUID | Thuộc tính | Hướng |
|---|---|---|---|
| Service khóa | `8a1c0001-5b7e-4e2b-9b6a-3c4d5e6f7a80` | quảng bá trong gói advertising | – |
| Command | `8a1c0002-5b7e-4e2b-9b6a-3c4d5e6f7a80` | Write (có phản hồi) | App → Khóa |
| Event | `8a1c0003-5b7e-4e2b-9b6a-3c4d5e6f7a80` | Notify | Khóa → App |
| Log | `8a1c0004-5b7e-4e2b-9b6a-3c4d5e6f7a80` | Notify | Khóa → App (nhật ký, gửi nhiều gói) |

- Tên quảng bá: `Khoabaomat`. App quét **lọc theo service UUID** nên không hiện thiết bị lạ.
- MTU: ESP32 đặt 247, nên mỗi gói chứa tối đa 244 byte dữ liệu. Nhật ký phải chia thành nhiều gói.
- ESP32 mặc định chỉ nhận **1 kết nối** cùng lúc. Khi điện thoại ngắt, khóa quảng bá lại để máy khác vào.

### 4.2. Định dạng gói

Byte đầu tiên là **loại gói**:

| Loại | Hướng | Nội dung | Mã hóa |
|---|---|---|---|
| `0x01` CHALLENGE_REQUEST | App → Khóa | `[0x01][keyId]` | Không |
| `0x81` CHALLENGE | Khóa → App | `[0x81][nonce 8 byte]`, nonce chỉ có hiệu lực 10 giây và dùng được 1 lần | Không |
| `0x02` SEALED_COMMAND | App → Khóa | `[0x02][keyId][IV 12][bản mã][tag 16]` | AES-256-GCM |
| `0x82` SEALED_REPLY | Khóa → App | Cùng định dạng với `0x02` | AES-256-GCM |

Phần bên trong khi đã giải mã:

```
Lệnh (App → Khóa):   [cmd 1B][counter 4B][nonce 8B][unixTime 4B][payload …]
Phản hồi (Khóa → App): [cmd 1B][result 1B][counter 4B][payload …]
```

- `keyId` được đưa vào **AAD** của GCM. Nếu ai đó đổi `keyId` trên đường truyền, gói sẽ bị từ chối.
- `IV` là 12 byte ngẫu nhiên, sinh mới cho mỗi gói.

### 4.3. Danh sách lệnh

| `cmd` | Lệnh | Payload gửi đi | Payload trả về | Quyền |
|---|---|---|---|---|
| `0x10` | UNLOCK | – | – | admin, member, guest (trong khung giờ) |
| `0x11` | LOCK | – | – | admin, member |
| `0x12` | STATUS | – | trạng thái chốt, nguồn, RSSI, số lần sai, giờ khóa | tất cả |
| `0x13` | SYNC_TIME | unixTime 4B | – | admin, member (tự gửi mỗi lần kết nối) |
| `0x20` | GET_LOGS | chỉ số bắt đầu 4B | số bản ghi; dữ liệu gửi qua characteristic Log | admin |
| `0x30` / `0x31` | ENROLL_RFID / DELETE_RFID | memberId / UID | UID vừa quét | admin |
| `0x32` / `0x33` | ENROLL_FINGER / DELETE_FINGER | memberId / ID AS608 | tiến trình (đặt tay lần 1, lần 2), ID | admin |
| `0x34` | SET_PIN | memberId + PIN (khóa chỉ lưu bản băm) | – | admin |
| `0x35` | ADD_GUEST_TOTP | secret, từ – đến (unixTime) | guestId | admin |
| `0x40` | PAIR_BEGIN | khóa công khai X25519 của điện thoại (32B) | khóa công khai của khóa (32B) + keyId | chỉ khi khóa đang ở chế độ ghép đôi |
| `0x41` | REVOKE_PHONE | keyId cần thu hồi | – | admin |

Mã kết quả: `0x00` OK · `0x01` nonce sai/hết hạn · `0x02` bộ đếm không tăng (nghi phát lại) · `0x03` không đủ quyền / đã bị thu hồi · `0x04` khóa đang bận.

### 4.4. Đồng bộ giờ

ESP32 **không có pin RTC**, nên mất điện là mất giờ. Vì vậy:
- Mỗi lần kết nối, app gửi `SYNC_TIME` ngay sau khi ghép đôi xong.
- Các bản ghi nhật ký tạo ra khi khóa chưa có giờ sẽ lưu theo `millis()` kèm cờ "chưa đồng bộ". App hiển thị những bản ghi này là "không rõ giờ".
- Mã PIN khách TOTP chỉ được chấp nhận khi khóa đã có giờ đúng.

---

## 5. Bảo mật

### 5.1. Ghép đôi điện thoại với khóa (chỉ làm 1 lần)

Ghép đôi bằng **nút vật lý GPIO34** để chứng minh người dùng đang đứng tại cửa. Bước xác nhận dùng **bàn phím của khóa**, để không ai chen vào giữa được (chống MITM).

```
Người dùng                 App                                   Khóa ESP32
    │ giữ nút mở 5 giây ────────────────────────────────────────►  │ vào CHẾ ĐỘ GHÉP ĐÔI (60 giây)
    │                       │                                      │ LED xanh nháy, quảng bá cờ "pairing"
    │ bấm "Thêm khóa" ───►   │ quét, kết nối                        │
    │                       │ tạo cặp khóa X25519 (a, A)           │
    │                       │── PAIR_BEGIN [A] ──────────────────► │ tạo cặp (b, B), cấp keyId
    │                       │ ◄──────────────── [B][keyId] ─────── │
    │                       │ chung = X25519(a, B)                 │ chung = X25519(b, A)
    │                       │ khóaAES = HKDF(chung, keyId)         │ khóaAES = HKDF(chung, keyId)
    │                       │ mã 6 số = HKDF(chung, "confirm")      │ mã 6 số = HKDF(chung, "confirm")
    │ ◄── hiện "Gõ 482915#  │                                      │
    │      trên khóa"       │                                      │
    │ gõ 482915# trên bàn phím ────────────────────────────────────► │ so khớp mã → lưu khóaAES vào NVS
    │                       │ ◄──────────────── PAIRED ─────────── │ buzzer kêu 2 tiếng
    │                       │ lưu khóaAES vào flutter_secure_storage│
```

- Người đầu tiên ghép đôi là **admin**. Các điện thoại sau phải được admin cho phép trên app, ngoài việc giữ nút trên khóa.
- Nếu có kẻ chen giữa, mã 6 số trên app và mã khóa tự tính sẽ khác nhau, nên khóa từ chối ghép đôi.

### 5.2. Mỗi lệnh hằng ngày: challenge–response

1. App gửi `CHALLENGE_REQUEST`, khóa trả về **nonce ngẫu nhiên 8 byte**. Nonce chỉ có hiệu lực 10 giây và dùng được 1 lần.
2. App đóng gói `[cmd][counter][nonce][unixTime]`, mã hóa bằng AES-256-GCM với khóa riêng của điện thoại.
3. Khóa kiểm tra theo thứ tự:
   - Tag GCM đúng.
   - Nonce khớp với nonce vừa cấp và còn hạn.
   - `counter` lớn hơn lần trước của chính điện thoại đó.
   - Quyền của điện thoại.

   Đủ cả 4 điều kiện thì khóa mới đóng relay.
4. Kẻ nghe lén thu được gói tin cũng không phát lại được, vì nonce đã bị hủy và bộ đếm đã tăng.

### 5.3. Bảo vệ khóa AES trên điện thoại

| Mức | Cách làm | Ghi chú |
|---|---|---|
| Cơ bản (code mẫu) | `flutter_secure_storage`, chỉ đọc khóa **sau khi** `local_auth` trả về thành công | Trên máy đã root, có thể vượt qua bước kiểm tra `local_auth` |
| Nâng cao | Bọc khóa AES bằng một khóa trong **Android Keystore** có `setUserAuthenticationRequired(true)` và `setInvalidatedByBiometricEnrollment(true)`, giải mã qua `BiometricPrompt.CryptoObject` | Đã có sẵn trong project **faceid**: `BiometricLock.java` + MethodChannel `faceid/biometric_lock`. Chép sang là dùng được. iOS dùng Keychain với `SecAccessControl` `.biometryCurrentSet` |

### 5.4. Các rủi ro và cách xử lý

| Rủi ro | Biện pháp | Giới hạn còn lại |
|---|---|---|
| Nghe lén BLE | AES-256-GCM, mỗi điện thoại một khóa riêng | – |
| Phát lại gói cũ | Nonce dùng 1 lần + bộ đếm tăng dần | – |
| Mất điện thoại | Kẻ nhặt được vẫn phải qua sinh trắc học; admin thu hồi `keyId` bằng `REVOKE_PHONE` | Cần một điện thoại admin khác, hoặc khôi phục cài đặt gốc tại khóa |
| Chen giữa lúc ghép đôi | Nút vật lý + mã 6 số gõ trên bàn phím | – |
| Tấn công relay (kéo dài khoảng cách BLE) | Lệnh phải xuất phát từ thao tác sinh trắc học trên máy, không tự mở khi lại gần | Không chống được hoàn toàn nếu chỉ dùng BLE |
| Sao chép thẻ RFID | Không dùng thẻ làm cách mở duy nhất cho cửa quan trọng | Thẻ MIFARE Classic chỉ kiểm tra UID nên **sao chép được**. Muốn an toàn hơn, nâng cấp lên thẻ DESFire EV2/EV3 |
| Ảnh/video khuôn mặt (chế độ FaceNet) | Kiểm tra nháy mắt, chất lượng ảnh, sai 3 lần thì khóa tạm | Không bằng Face ID 3D, nên mặc định tắt |
| Dò mã PIN trên bàn phím | Sai 5 lần thì khóa bàn phím 5 phút, buzzer báo, ghi nhật ký; PIN lưu dạng băm SHA-256 + salt | – |
| Đọc trộm flash ESP32 | Bật Flash Encryption + Secure Boot của ESP32 | ⚠️ Ghi **eFuse không đảo ngược được**. Chỉ làm ở bản cuối, sau khi đã thử kỹ trên board phụ |

---

## 6. Code mẫu

Các khối code dưới đây được chép nguyên văn từ project. Đường dẫn trên mỗi khối là vị trí file thật.
- **Dart**: `flutter analyze` → *No issues found*; `flutter test` → *8/8 tests passed*; integration test với ESP32 thật → *passed*.
- **ESP32**: `firmware/smart_lock` dùng 1.119.279 byte flash (35% phân vùng Huge APP) và 41.404 byte RAM (12%).

### 6.1. Hằng số giao thức – `lib/core/ble/lock_protocol.dart`

```dart
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

/// UUID dịch vụ BLE của khoá (tự định nghĩa, 128-bit) – phải trùng với firmware ESP32.
abstract final class LockUuids {
  static final service = Guid('8a1c0001-5b7e-4e2b-9b6a-3c4d5e6f7a80');
  static final command = Guid('8a1c0002-5b7e-4e2b-9b6a-3c4d5e6f7a80'); // App → Khoá (write)
  static final event = Guid('8a1c0003-5b7e-4e2b-9b6a-3c4d5e6f7a80'); // Khoá → App (notify)
  static final log = Guid('8a1c0004-5b7e-4e2b-9b6a-3c4d5e6f7a80'); // Khoá → App (notify, nhật ký)
}

/// Byte đầu tiên của mỗi gói BLE cho biết loại gói.
abstract final class FrameKind {
  static const challengeRequest = 0x01; // App → Khoá, bản rõ: [0x01][keyId]
  static const sealedCommand = 0x02; // App → Khoá, đã mã hoá: [0x02][keyId][IV 12][bản mã][tag 16]
  static const challenge = 0x81; // Khoá → App, bản rõ: [0x81][nonce 8]
  static const sealedReply = 0x82; // Khoá → App, đã mã hoá, cùng định dạng với 0x02
}

/// Mã lệnh nằm trong phần đã mã hoá.
abstract final class LockCmd {
  static const unlock = 0x10;
  static const lock = 0x11;
  static const status = 0x12;
  static const syncTime = 0x13;
  static const getLogs = 0x20;
  static const enrollRfid = 0x30;
  static const deleteRfid = 0x31;
  static const enrollFinger = 0x32;
  static const deleteFinger = 0x33;
  static const setPin = 0x34;
  static const addGuestTotp = 0x35;
}

/// Mã kết quả khoá trả về.
abstract final class LockResult {
  static const ok = 0x00;
  static const badNonce = 0x01; // nonce sai / hết hạn / đã dùng
  static const badCounter = 0x02; // bộ đếm không tăng → nghi phát lại
  static const denied = 0x03; // khoá của điện thoại bị thu hồi / không đủ quyền
  static const busy = 0x04; // khoá đang bận (đang đăng ký vân tay…)

  static String describe(int code) => switch (code) {
        ok => 'Thành công',
        badNonce => 'Phiên đã hết hạn, thử lại',
        badCounter => 'Gói tin bị phát lại – đã từ chối',
        denied => 'Điện thoại này không còn quyền mở khoá',
        busy => 'Khoá đang bận',
        _ => 'Lỗi không xác định (0x${code.toRadixString(16)})',
      };
}
```

### 6.2. Module kết nối BLE – `lib/features/device/data/ble_lock_data_source.dart`

Những điểm chính:
- Quét có lọc theo UUID của khóa.
- Lọc kết quả quét **lần nữa ở phía Dart**. Lý do: trên Windows, bộ lọc `withServices` của hệ điều hành vẫn trả về thiết bị lạ. Integration test đã bắt được lỗi này khi nó kết nối nhầm sang một thiết bị khác.
- `connect()` với `License.nonprofit` và MTU 247.
- `cancelWhenDisconnected` tự hủy việc nghe notify khi mất kết nối, để không bị rò rỉ.
- `request()` đăng ký nghe phản hồi **trước** khi ghi lệnh, nên không lỡ phản hồi đến quá nhanh.

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../../core/ble/lock_protocol.dart';

class BleException implements Exception {
  const BleException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Lớp dữ liệu BLE: quét, kết nối, gửi gói và nhận gói notify từ khoá.
/// Không biết gì về mã hoá – chỉ chuyển byte.
class BleLockDataSource {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _command;
  final _frames = StreamController<Uint8List>.broadcast();

  /// Mọi gói khoá gửi về qua characteristic Event.
  Stream<Uint8List> get frames => _frames.stream;

  Stream<BluetoothConnectionState> get connectionState =>
      _device?.connectionState ?? Stream.value(BluetoothConnectionState.disconnected);

  /// Quét khoá ở gần, chỉ lấy thiết bị quảng bá đúng service UUID của khoá.
  Future<Stream<List<ScanResult>>> scan({Duration timeout = const Duration(seconds: 10)}) async {
    final state = await FlutterBluePlus.adapterState
        .firstWhere((s) => s != BluetoothAdapterState.unknown);
    if (state != BluetoothAdapterState.on) {
      throw const BleException('Bluetooth đang tắt');
    }
    await FlutterBluePlus.startScan(withServices: [LockUuids.service], timeout: timeout);
    // Lọc lại phía Dart: bộ lọc của hệ điều hành không đáng tin trên mọi nền tảng
    // (Windows trả về cả thiết bị không quảng bá UUID này).
    return FlutterBluePlus.scanResults.map(
      (list) => list.where((r) => r.advertisementData.serviceUuids.contains(LockUuids.service)).toList(),
    );
  }

  Future<void> stopScan() => FlutterBluePlus.stopScan();

  Future<void> connect(BluetoothDevice device) async {
    // flutter_blue_plus 2.x bắt buộc khai báo giấy phép; đồ án học tập dùng License.nonprofit.
    await device.connect(license: License.nonprofit, timeout: const Duration(seconds: 15), mtu: 247);

    final services = await device.discoverServices();
    final service = services.where((s) => s.uuid == LockUuids.service).firstOrNull;
    if (service == null) {
      await device.disconnect();
      throw const BleException('Thiết bị này không phải khoá Khoabaomat');
    }
    BluetoothCharacteristic find(Guid uuid) => service.characteristics.firstWhere((c) => c.uuid == uuid);

    final event = find(LockUuids.event);
    final sub = event.onValueReceived.listen((v) => _frames.add(Uint8List.fromList(v)));
    device.cancelWhenDisconnected(sub); // tự huỷ khi mất kết nối, tránh rò rỉ
    await event.setNotifyValue(true);

    _command = find(LockUuids.command);
    _device = device;
  }

  Future<void> disconnect() async {
    await _device?.disconnect();
    _device = null;
    _command = null;
  }

  Future<void> write(List<int> frame) async {
    final c = _command;
    if (c == null) throw const BleException('Chưa kết nối khoá');
    await c.write(frame); // write có phản hồi: biết chắc khoá đã nhận
  }

  /// Gửi 1 gói rồi chờ gói trả về đầu tiên có byte đầu = [replyKind].
  Future<Uint8List> request(
    List<int> frame, {
    required int replyKind,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // Đăng ký nghe TRƯỚC khi ghi để không lỡ gói trả về quá nhanh.
    final reply = frames.firstWhere((f) => f.isNotEmpty && f[0] == replyKind).timeout(timeout);
    try {
      await write(frame);
    } catch (_) {
      reply.ignore();
      rethrow;
    }
    return reply;
  }
}
```

Cách dùng trên màn hình quét:

```dart
final ble = sl<BleLockDataSource>();
final results = await ble.scan();
final sub = results.listen((list) {
  for (final r in list) {
    debugPrint('${r.device.platformName}  ${r.device.remoteId}  RSSI ${r.rssi}');
  }
});
// … người dùng chọn 1 khóa:
await ble.stopScan();
await sub.cancel();
await ble.connect(chosen.device);
```

### 6.3. Module xác thực sinh trắc học – `lib/features/biometric/data/biometric_auth_service.dart`

```dart
import 'package:local_auth/local_auth.dart';

enum BiometricOutcome {
  success('Xác thực thành công'),
  canceled('Đã huỷ xác thực'),
  notAvailable('Máy không hỗ trợ sinh trắc học'),
  notEnrolled('Chưa cài vân tay / khuôn mặt trong Cài đặt của máy'),
  lockedOut('Sai quá nhiều lần, sinh trắc học tạm bị khoá'),
  failed('Xác thực thất bại');

  const BiometricOutcome(this.message);
  final String message;
}

/// Xác thực bằng sinh trắc học của hệ điều hành (Face ID / Touch ID / Android BiometricPrompt)
/// qua local_auth 3.x.
class BiometricAuthService {
  BiometricAuthService([LocalAuthentication? auth]) : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  /// Có dùng được sinh trắc học "mạnh" không. Trên Android, mở khoá khuôn mặt của nhiều máy
  /// chỉ là loại weak (chụp 2D) – không đủ tin cậy để mở cửa nên bị loại.
  Future<bool> hasStrongBiometric() async {
    if (!await _auth.isDeviceSupported()) return false;
    final types = await _auth.getAvailableBiometrics();
    return types.contains(BiometricType.strong) || // Android lớp 3
        types.contains(BiometricType.face) || // iOS Face ID
        types.contains(BiometricType.fingerprint); // iOS Touch ID / Android cũ
  }

  Future<BiometricOutcome> authenticate(String reason) async {
    try {
      final ok = await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true, // không cho dùng mã PIN màn hình khoá thay thế
        persistAcrossBackgrounding: true, // không huỷ khi app bị đẩy xuống nền giữa chừng
      );
      return ok ? BiometricOutcome.success : BiometricOutcome.failed;
    } on LocalAuthException catch (e) {
      return switch (e.code) {
        LocalAuthExceptionCode.userCanceled ||
        LocalAuthExceptionCode.systemCanceled ||
        LocalAuthExceptionCode.userRequestedFallback =>
          BiometricOutcome.canceled,
        LocalAuthExceptionCode.noBiometricHardware ||
        LocalAuthExceptionCode.biometricHardwareTemporarilyUnavailable =>
          BiometricOutcome.notAvailable,
        LocalAuthExceptionCode.noBiometricsEnrolled ||
        LocalAuthExceptionCode.noCredentialsSet =>
          BiometricOutcome.notEnrolled,
        LocalAuthExceptionCode.temporaryLockout ||
        LocalAuthExceptionCode.biometricLockout =>
          BiometricOutcome.lockedOut,
        _ => BiometricOutcome.failed,
      };
    }
  }
}
```

### 6.4. Mã hóa – `lib/core/crypto/lock_crypto.dart`

```dart
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Kết quả ghép đôi: khoá AES riêng của điện thoại + mã 6 số để người dùng
/// gõ trên bàn phím của khoá (xác nhận không có ai chen giữa – chống MITM).
typedef PairingSecrets = ({SecretKey phoneKey, String confirmCode});

/// Mã hoá lệnh gửi khoá bằng AES-256-GCM.
///
/// Gói đã mã hoá: `[keyId 1B][IV 12B][bản mã][tag 16B]`, keyId được đưa vào AAD.
/// Bản rõ của lệnh: `[cmd 1B][counter 4B][lockNonce 8B][unixTime 4B][payload…]`.
class LockCrypto {
  LockCrypto({Random? random}) : _random = random ?? Random.secure();

  final Random _random;
  static final _aes = AesGcm.with256bits();
  static final _x25519 = X25519();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static const ivLength = 12;
  static const tagLength = 16;

  // ---------------- Ghép đôi (chỉ chạy 1 lần cho mỗi điện thoại) ----------------

  Future<SimpleKeyPair> newPairingKeyPair() => _x25519.newKeyPair();

  /// ECDH X25519 → HKDF-SHA256 → khoá AES 32 byte cho cặp (điện thoại, khoá) và mã xác nhận.
  Future<PairingSecrets> completePairing({
    required SimpleKeyPair myKeyPair,
    required List<int> lockPublicKey,
    required int keyId,
  }) async {
    final shared = await _x25519.sharedSecretKey(
      keyPair: myKeyPair,
      remotePublicKey: SimplePublicKey(lockPublicKey, type: KeyPairType.x25519),
    );
    final salt = utf8.encode('khoabaomat-v1');
    final phoneKey = await _hkdf.deriveKey(secretKey: shared, nonce: salt, info: [keyId]);
    final codeKey = await _hkdf.deriveKey(secretKey: shared, nonce: salt, info: utf8.encode('confirm'));
    final b = await codeKey.extractBytes();
    final n = ((b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]) & 0x7fffffff;
    return (phoneKey: phoneKey, confirmCode: (n % 1000000).toString().padLeft(6, '0'));
  }

  // ---------------- Lệnh hằng ngày ----------------

  Future<Uint8List> sealCommand({
    required SecretKey phoneKey,
    required int keyId,
    required int cmd,
    required int counter,
    required List<int> lockNonce,
    List<int> payload = const [],
    DateTime? now,
  }) async {
    final unixTime = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final plain = (BytesBuilder()
          ..addByte(cmd)
          ..add(_u32(counter))
          ..add(lockNonce)
          ..add(_u32(unixTime))
          ..add(payload))
        .toBytes();
    final iv = List<int>.generate(ivLength, (_) => _random.nextInt(256));
    final box = await _aes.encrypt(plain, secretKey: phoneKey, nonce: iv, aad: [keyId]);
    return Uint8List.fromList([keyId, ...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// Giải mã gói trả về từ khoá. Gói bị sửa dù 1 bit → ném [SecretBoxAuthenticationError].
  Future<Uint8List> open({required SecretKey phoneKey, required List<int> sealed}) async {
    if (sealed.length < 1 + ivLength + tagLength) {
      throw const FormatException('Gói mã hoá quá ngắn');
    }
    final box = SecretBox(
      sealed.sublist(1 + ivLength, sealed.length - tagLength),
      nonce: sealed.sublist(1, 1 + ivLength),
      mac: Mac(sealed.sublist(sealed.length - tagLength)),
    );
    final plain = await _aes.decrypt(box, secretKey: phoneKey, aad: [sealed[0]]);
    return Uint8List.fromList(plain);
  }

  static List<int> _u32(int v) => [(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff];

  static int readU32(List<int> b, int offset) =>
      (b[offset] << 24) | (b[offset + 1] << 16) | (b[offset + 2] << 8) | b[offset + 3];
}
```

### 6.5. Lưu khóa bí mật – `lib/core/storage/lock_key_store.dart`

```dart
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Thông tin bí mật của 1 khoá đã ghép đôi với điện thoại này.
class LockCredential {
  const LockCredential({required this.lockId, required this.keyId, required this.key});

  final String lockId; // địa chỉ BLE (remoteId) của khoá
  final int keyId; // số thứ tự điện thoại trong bộ nhớ của khoá (1..N)
  final SecretKey key; // khoá AES-256 riêng của điện thoại
}

/// Lưu khoá AES và bộ đếm chống phát lại trong flutter_secure_storage
/// (Android Keystore / iOS Keychain). Không bao giờ ghi ra SharedPreferences hay file thường.
class LockKeyStore {
  LockKeyStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  String _name(String lockId) => 'lock.$lockId';

  Future<void> save(String lockId, int keyId, SecretKey key) async {
    final bytes = await key.extractBytes();
    await _storage.write(
      key: _name(lockId),
      value: jsonEncode({'keyId': keyId, 'key': base64Encode(bytes), 'counter': 0}),
    );
  }

  Future<LockCredential?> read(String lockId) async {
    final raw = await _storage.read(key: _name(lockId));
    if (raw == null) return null;
    final m = jsonDecode(raw) as Map<String, dynamic>;
    return LockCredential(
      lockId: lockId,
      keyId: m['keyId'] as int,
      key: SecretKey(base64Decode(m['key'] as String)),
    );
  }

  /// Tăng và trả về bộ đếm lệnh. Khoá chỉ nhận lệnh có bộ đếm lớn hơn lần trước.
  Future<int> nextCounter(String lockId) async {
    final raw = await _storage.read(key: _name(lockId));
    if (raw == null) throw StateError('Khoá $lockId chưa ghép đôi');
    final m = jsonDecode(raw) as Map<String, dynamic>;
    final next = (m['counter'] as int) + 1;
    m['counter'] = next;
    await _storage.write(key: _name(lockId), value: jsonEncode(m));
    return next;
  }

  Future<void> remove(String lockId) => _storage.delete(key: _name(lockId));
}
```

### 6.6. Gửi lệnh an toàn – `lib/core/ble/secure_command_sender.dart`

Phần dùng chung cho mọi lệnh: xin nonce → mã hóa → gửi → giải mã và kiểm tra phản hồi. Mở khóa, khóa ngay và đọc trạng thái đều đi qua đây.

```dart
import 'dart:typed_data';

import '../../features/device/data/ble_lock_data_source.dart';
import '../crypto/lock_crypto.dart';
import '../storage/lock_key_store.dart';
import 'lock_protocol.dart';

/// Khoá trả về mã kết quả khác OK.
class LockCommandException implements Exception {
  const LockCommandException(this.result);
  final int result;
  String get message => LockResult.describe(result);
  @override
  String toString() => message;
}

/// Gửi 1 lệnh an toàn tới khoá: xin nonce → mã hoá AES-GCM → gửi → giải mã và kiểm tra phản hồi.
/// Dùng chung cho mọi lệnh (UNLOCK, LOCK, STATUS…). Trả về phần payload của phản hồi.
class SecureCommandSender {
  SecureCommandSender(this._ble, this._keys, this._crypto);

  final BleLockDataSource _ble;
  final LockKeyStore _keys;
  final LockCrypto _crypto;

  Future<Uint8List> send(LockCredential cred, int cmd, {List<int> payload = const []}) async {
    // 1. Xin nonce dùng 1 lần (chống phát lại gói cũ)
    final challenge = await _ble.request(
      [FrameKind.challengeRequest, cred.keyId],
      replyKind: FrameKind.challenge,
    );
    if (challenge.length != 9) throw const FormatException('Gói challenge không hợp lệ');

    // 2. Mã hoá lệnh kèm nonce + bộ đếm tăng dần
    final counter = await _keys.nextCounter(cred.lockId);
    final sealed = await _crypto.sealCommand(
      phoneKey: cred.key,
      keyId: cred.keyId,
      cmd: cmd,
      counter: counter,
      lockNonce: challenge.sublist(1, 9),
      payload: payload,
    );
    final reply = await _ble.request(
      [FrameKind.sealedCommand, ...sealed],
      replyKind: FrameKind.sealedReply,
    );

    // 3. Phản hồi: [cmd][result][counter 4B][payload…] – phải khớp lệnh vừa gửi
    final plain = await _crypto.open(phoneKey: cred.key, sealed: reply.sublist(1));
    if (plain.length < 6 || plain[0] != cmd || LockCrypto.readU32(plain, 2) != counter) {
      throw const FormatException('Phản hồi không khớp lệnh vừa gửi');
    }
    if (plain[1] != LockResult.ok) throw LockCommandException(plain[1]);
    return Uint8List.sublistView(plain, 6);
  }
}
```

### 6.7. Use case mở khóa – `lib/features/unlock/domain/unlock_with_biometric.dart`

```dart
import 'dart:async';

import 'package:cryptography/cryptography.dart';

import '../../../core/ble/lock_protocol.dart';
import '../../../core/ble/secure_command_sender.dart';
import '../../../core/storage/lock_key_store.dart';
import '../../biometric/data/biometric_auth_service.dart';
import '../../device/data/ble_lock_data_source.dart';

sealed class UnlockResult {
  const UnlockResult();
}

final class UnlockSuccess extends UnlockResult {
  const UnlockSuccess();
}

final class UnlockFailure extends UnlockResult {
  const UnlockFailure(this.reason);
  final String reason;
}

enum UnlockStep { authenticating, sending }

/// Use case: xác thực sinh trắc trên điện thoại → gửi lệnh UNLOCK đã mã hoá.
class UnlockWithBiometric {
  UnlockWithBiometric(this._biometric, this._keys, this._sender);

  final BiometricAuthService _biometric;
  final LockKeyStore _keys;
  final SecureCommandSender _sender;

  Future<UnlockResult> call(String lockId, {void Function(UnlockStep step)? onStep}) async {
    // 1. Xác thực người dùng trên điện thoại
    onStep?.call(UnlockStep.authenticating);
    final bio = await _biometric.authenticate('Xác thực để mở cửa');
    if (bio != BiometricOutcome.success) return UnlockFailure(bio.message);

    // 2. Lấy khoá AES riêng của điện thoại (chỉ đọc SAU khi xác thực thành công)
    final cred = await _keys.read(lockId);
    if (cred == null) return const UnlockFailure('Điện thoại chưa ghép đôi với khoá này');

    // 3. Gửi lệnh mở (challenge → AES-GCM → kiểm tra phản hồi)
    try {
      onStep?.call(UnlockStep.sending);
      await _sender.send(cred, LockCmd.unlock);
      return const UnlockSuccess();
    } on LockCommandException catch (e) {
      return UnlockFailure(e.message);
    } on TimeoutException {
      return const UnlockFailure('Khoá không phản hồi – hãy lại gần cửa hơn');
    } on SecretBoxAuthenticationError {
      return const UnlockFailure('Phản hồi bị sửa đổi hoặc sai khoá – đã từ chối');
    } on BleException catch (e) {
      return UnlockFailure(e.message);
    } on FormatException catch (e) {
      return UnlockFailure(e.message);
    }
  }
}
```

### 6.8. Bloc mở khóa – `lib/features/unlock/presentation/unlock_bloc.dart`

```dart
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../domain/unlock_with_biometric.dart';

sealed class UnlockEvent {
  const UnlockEvent();
}

final class UnlockPressed extends UnlockEvent {
  const UnlockPressed(this.lockId);
  final String lockId;
}

sealed class UnlockState extends Equatable {
  const UnlockState();
  @override
  List<Object?> get props => [];
}

final class UnlockIdle extends UnlockState {
  const UnlockIdle();
}

final class UnlockInProgress extends UnlockState {
  const UnlockInProgress(this.step);
  final UnlockStep step;
  @override
  List<Object?> get props => [step];
}

final class UnlockSucceeded extends UnlockState {
  const UnlockSucceeded();
}

final class UnlockFailed extends UnlockState {
  const UnlockFailed(this.message);
  final String message;
  @override
  List<Object?> get props => [message];
}

class UnlockBloc extends Bloc<UnlockEvent, UnlockState> {
  UnlockBloc(this._unlock) : super(const UnlockIdle()) {
    on<UnlockPressed>(_onPressed);
  }

  final UnlockWithBiometric _unlock;

  Future<void> _onPressed(UnlockPressed event, Emitter<UnlockState> emit) async {
    if (state is UnlockInProgress) return; // bấm liên tục không gửi 2 lệnh
    final result = await _unlock(event.lockId, onStep: (s) => emit(UnlockInProgress(s)));
    emit(switch (result) {
      UnlockSuccess() => const UnlockSucceeded(),
      UnlockFailure(:final reason) => UnlockFailed(reason),
    });
  }
}
```

### 6.9. Nút mở khóa trên giao diện – `lib/features/unlock/presentation/unlock_button.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/di/injection.dart';
import '../domain/unlock_with_biometric.dart';
import 'unlock_bloc.dart';

/// Nút mở khoá. Tự đổi chữ theo từng bước và báo kết quả bằng SnackBar.
class UnlockButton extends StatelessWidget {
  const UnlockButton({super.key, required this.lockId, this.onUnlocked});

  final String lockId;
  final VoidCallback? onUnlocked;

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => sl<UnlockBloc>(),
      child: BlocConsumer<UnlockBloc, UnlockState>(
        listener: (context, state) {
          final message = switch (state) {
            UnlockSucceeded() => 'Đã mở cửa',
            UnlockFailed(:final message) => message,
            _ => null,
          };
          if (message != null) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
          }
          if (state is UnlockSucceeded) onUnlocked?.call();
        },
        builder: (context, state) {
          final busy = state is UnlockInProgress;
          final label = switch (state) {
            UnlockInProgress(step: UnlockStep.authenticating) => 'Đang xác thực…',
            UnlockInProgress(step: UnlockStep.sending) => 'Đang mở…',
            _ => 'Mở cửa',
          };
          return FilledButton.icon(
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
            onPressed: busy ? null : () => context.read<UnlockBloc>().add(UnlockPressed(lockId)),
            icon: busy
                ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.lock_open_rounded),
            label: Text(label),
          );
        },
      ),
    );
  }
}
```

### 6.10. Đăng ký phụ thuộc – `lib/core/di/injection.dart`

```dart
import 'package:get_it/get_it.dart';

import '../../features/biometric/data/biometric_auth_service.dart';
import '../../features/device/data/ble_lock_data_source.dart';
import '../../features/device/domain/lock_status.dart';
import '../../features/device/presentation/device_cubit.dart';
import '../../features/device/presentation/scan_cubit.dart';
import '../../features/unlock/domain/unlock_with_biometric.dart';
import '../../features/unlock/presentation/unlock_bloc.dart';
import '../ble/secure_command_sender.dart';
import '../crypto/lock_crypto.dart';
import '../storage/lock_key_store.dart';

final sl = GetIt.instance;

/// Gọi 1 lần trong main() trước runApp().
void configureDependencies() {
  if (sl.isRegistered<BleLockDataSource>()) return;
  sl
    // data / core
    ..registerLazySingleton(BleLockDataSource.new)
    ..registerLazySingleton(BiometricAuthService.new)
    ..registerLazySingleton(LockKeyStore.new)
    ..registerLazySingleton(LockCrypto.new)
    ..registerLazySingleton(() => SecureCommandSender(sl(), sl(), sl()))
    // domain
    ..registerFactory(() => UnlockWithBiometric(sl(), sl(), sl()))
    ..registerFactory(() => ReadLockStatus(sl(), sl()))
    ..registerFactory(() => LockNow(sl(), sl()))
    // presentation
    ..registerFactory(() => ScanCubit(sl()))
    ..registerFactory(() => DeviceCubit(sl(), sl(), sl(), sl()))
    ..registerFactory(() => UnlockBloc(sl()));
}
```

### 6.11. Test – `test/lock_crypto_test.dart`, `test/unlock_bloc_test.dart`, `integration_test/ble_lock_test.dart`

```dart
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:khoabaomat/core/ble/lock_protocol.dart';
import 'package:khoabaomat/core/crypto/lock_crypto.dart';

void main() {
  final crypto = LockCrypto();

  test('ghép đôi: điện thoại và khoá tính ra cùng khoá AES và cùng mã xác nhận', () async {
    final phone = await crypto.newPairingKeyPair();
    final lock = await crypto.newPairingKeyPair(); // giả lập phía ESP32
    final phonePub = (await phone.extractPublicKey()).bytes;
    final lockPub = (await lock.extractPublicKey()).bytes;

    final a = await crypto.completePairing(myKeyPair: phone, lockPublicKey: lockPub, keyId: 3);
    final b = await crypto.completePairing(myKeyPair: lock, lockPublicKey: phonePub, keyId: 3);

    expect(await a.phoneKey.extractBytes(), await b.phoneKey.extractBytes());
    expect(a.confirmCode, b.confirmCode);
    expect(a.confirmCode, matches(RegExp(r'^\d{6}$')));
  });

  test('lệnh UNLOCK: khoá giải mã được đúng các trường', () async {
    final key = SecretKey(List<int>.generate(32, (i) => i));
    final nonce = [1, 2, 3, 4, 5, 6, 7, 8];
    final sealed = await crypto.sealCommand(
      phoneKey: key, keyId: 3, cmd: LockCmd.unlock, counter: 42, lockNonce: nonce,
      now: DateTime.fromMillisecondsSinceEpoch(1760000000 * 1000),
    );

    final plain = await crypto.open(phoneKey: key, sealed: sealed); // cùng định dạng 2 chiều
    expect(sealed[0], 3);
    expect(plain[0], LockCmd.unlock);
    expect(LockCrypto.readU32(plain, 1), 42);
    expect(plain.sublist(5, 13), nonce);
    expect(LockCrypto.readU32(plain, 13), 1760000000);
  });

  test('gói bị sửa 1 bit hoặc đổi keyId thì bị từ chối', () async {
    final key = SecretKey(List<int>.generate(32, (i) => i));
    final sealed = await crypto.sealCommand(
      phoneKey: key, keyId: 3, cmd: LockCmd.unlock, counter: 1, lockNonce: List.filled(8, 0),
    );
    final flipped = [...sealed]..[20] ^= 0x01;
    final otherId = [...sealed]..[0] = 4;
    await expectLater(crypto.open(phoneKey: key, sealed: flipped), throwsA(isA<SecretBoxAuthenticationError>()));
    await expectLater(crypto.open(phoneKey: key, sealed: otherId), throwsA(isA<SecretBoxAuthenticationError>()));
  });
}
```

```dart
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:khoabaomat/features/unlock/domain/unlock_with_biometric.dart';
import 'package:khoabaomat/features/unlock/presentation/unlock_bloc.dart';
import 'package:mocktail/mocktail.dart';

class MockUnlock extends Mock implements UnlockWithBiometric {}

void main() {
  late MockUnlock unlock;
  setUp(() => unlock = MockUnlock());

  blocTest<UnlockBloc, UnlockState>(
    'mở thành công: xác thực → gửi → thành công',
    build: () {
      when(() => unlock(any(), onStep: any(named: 'onStep'))).thenAnswer((inv) async {
        final onStep = inv.namedArguments[#onStep] as void Function(UnlockStep);
        UnlockStep.values.forEach(onStep);
        return const UnlockSuccess();
      });
      return UnlockBloc(unlock);
    },
    act: (b) => b.add(const UnlockPressed('AA:BB:CC:DD:EE:FF')),
    expect: () => const [
      UnlockInProgress(UnlockStep.authenticating),
      UnlockInProgress(UnlockStep.sending),
      UnlockSucceeded(),
    ],
  );

  blocTest<UnlockBloc, UnlockState>(
    'huỷ quét khuôn mặt thì báo lỗi, không gửi lệnh',
    build: () {
      when(() => unlock(any(), onStep: any(named: 'onStep')))
          .thenAnswer((_) async => const UnlockFailure('Đã huỷ xác thực'));
      return UnlockBloc(unlock);
    },
    act: (b) => b.add(const UnlockPressed('AA:BB:CC:DD:EE:FF')),
    expect: () => const [UnlockFailed('Đã huỷ xác thực')],
  );
}
```

Integration test chạy với **ESP32 thật** (máy chạy test cần có Bluetooth LE: điện thoại Android hoặc laptop Windows):

```dart
// Test với ESP32 thật qua Bluetooth (chạy trên Windows có BLE hoặc điện thoại Android):
//   flutter test integration_test/ble_lock_test.dart -d windows
// Yêu cầu: ESP32 đang chạy firmware/smart_lock (giai đoạn 1) và ở gần máy.
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:khoabaomat/core/ble/lock_protocol.dart';
import 'package:khoabaomat/core/ble/secure_command_sender.dart';
import 'package:khoabaomat/core/di/injection.dart';
import 'package:khoabaomat/core/dev/demo_pairing.dart';
import 'package:khoabaomat/core/storage/lock_key_store.dart';
import 'package:khoabaomat/features/device/data/ble_lock_data_source.dart';
import 'package:khoabaomat/features/device/domain/lock_status.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  configureDependencies();

  testWidgets('quét → kết nối → STATUS → MỞ → STATUS → KHOÁ', (tester) async {
    final ble = sl<BleLockDataSource>();
    final keys = sl<LockKeyStore>();
    final sender = sl<SecureCommandSender>();
    final readStatus = sl<ReadLockStatus>();

    // 1. Quét theo service UUID
    final results = await ble.scan(timeout: const Duration(seconds: 15));
    final found = await results.firstWhere((l) => l.isNotEmpty).timeout(const Duration(seconds: 20));
    await ble.stopScan();
    final device = found.first.device;
    debugPrint('Tìm thấy: ${device.platformName} ${device.remoteId} RSSI ${found.first.rssi}');

    // 2. Kết nối + khoá demo của giai đoạn 1
    await ble.connect(device);
    expect(device.isConnected, isTrue);
    final lockId = device.remoteId.str;
    await seedDemoCredential(keys, lockId);
    final cred = (await keys.read(lockId))!;

    // 3. STATUS
    final before = await readStatus(lockId);
    debugPrint('Trước: mở=${before.unlocked}, chạy ${before.uptime.inSeconds}s, ${before.unlockCount} lần');

    // 4. MỞ (gửi thẳng lệnh, bỏ qua sinh trắc học vì test tự động)
    await sender.send(cred, LockCmd.unlock);
    final opened = await readStatus(lockId);
    expect(opened.unlocked, isTrue);
    expect(opened.unlockCount, before.unlockCount + 1);

    // 5. KHOÁ ngay
    await sender.send(cred, LockCmd.lock);
    final closed = await readStatus(lockId);
    expect(closed.unlocked, isFalse);
    debugPrint('Sau: mở=${closed.unlocked}, ${closed.unlockCount} lần');

    await ble.disconnect();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
```

### 6.12. Phía ESP32 – `firmware/smart_lock/` (giai đoạn 1)

Firmware dùng **đúng định dạng gói** với code Dart ở trên:
- Cấp nonce, giải mã AES-GCM bằng mbedtls, kiểm tra nonce và bộ đếm.
- Xử lý các lệnh UNLOCK (đóng relay GPIO22 trong 5 giây), LOCK và STATUS, rồi trả phản hồi đã mã hóa.

Thư viện mbedtls trong core esp32 3.3.12 đã bật sẵn `GCM`, `ECDH`, `CURVE25519` và `HKDF`, nên viết thêm phần ghép đôi X25519 trên ESP32 không cần cài thư viện nào khác.

```cpp
// Cau hinh chung cho firmware khoa - chan GPIO theo SO_DO_NOI_DAY.md
#pragma once

// ---- BLE (phai trung voi lib/core/ble/lock_protocol.dart) ----
#define LOCK_BLE_NAME "Khoabaomat"
#define SERVICE_UUID  "8a1c0001-5b7e-4e2b-9b6a-3c4d5e6f7a80"
#define CMD_UUID      "8a1c0002-5b7e-4e2b-9b6a-3c4d5e6f7a80"  // App -> Khoa (write)
#define EVT_UUID      "8a1c0003-5b7e-4e2b-9b6a-3c4d5e6f7a80"  // Khoa -> App (notify)

// ---- Relay chot khoa ----
#define RELAY_PIN 22
#define RELAY_ON  HIGH  // doi thanh LOW neu module relay kich muc thap
const uint32_t UNLOCK_MS = 5000;

// ---- Giao thuc ----
const uint32_t NONCE_TTL_MS = 10000;

// Loai goi (byte dau)
#define FRAME_CHALLENGE_REQ 0x01
#define FRAME_SEALED_CMD    0x02
#define FRAME_CHALLENGE     0x81
#define FRAME_SEALED_REPLY  0x82

// Lenh
#define CMD_UNLOCK 0x10
#define CMD_LOCK   0x11
#define CMD_STATUS 0x12

// Ket qua
#define RES_OK          0x00
#define RES_BAD_NONCE   0x01
#define RES_BAD_COUNTER 0x02
#define RES_DENIED      0x03
#define RES_UNKNOWN_CMD 0x05
```

```cpp
// Firmware khoa thong minh - GIAI DOAN 1: BLE server + relay
// Nhan lenh da ma hoa AES-256-GCM tu app (dinh dang goi: KIEN_TRUC_APP.md muc 4).
//
// CANH BAO GIAI DOAN 1: khoa AES cua dien thoai #1 dang la 32 byte 0 (DEMO_KEY) de test.
// Giai doan 2 se thay bang khoa tao luc ghep doi (X25519 + HKDF) va luu NVS.
//
// Serial: 115200 baud

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLE2902.h>
#include "mbedtls/gcm.h"
#include "esp_random.h"
#include "config.h"

struct Phone { uint8_t id; uint8_t key[32]; uint32_t lastCounter; bool active; };
Phone phones[] = { {1, {0}, 0, true} };  // DEMO_KEY - chi dung de test giai doan 1

BLECharacteristic *evtChar;
volatile bool clientConnected = false;
uint8_t pendingNonce[8];
bool nonceValid = false;
uint32_t nonceAt = 0;
volatile bool relayOn = false;
volatile uint32_t relayOffAt = 0;
uint32_t unlockCount = 0;

Phone *findPhone(uint8_t id) {
  for (auto &p : phones) if (p.id == id && p.active) return &p;
  return nullptr;
}

void sendFrame(const uint8_t *data, size_t len) {
  evtChar->setValue(data, len);
  evtChar->notify();
}

void setRelay(bool on) {
  digitalWrite(RELAY_PIN, on ? RELAY_ON : !RELAY_ON);
  relayOn = on;
  relayOffAt = on ? millis() + UNLOCK_MS : 0;
}

// Phan hoi: [0x82][keyId][IV 12][AES(cmd, result, counter 4B, payload)][tag 16]
void sendSealedReply(Phone *p, uint8_t cmd, uint8_t result, uint32_t counter,
                     const uint8_t *payload = nullptr, size_t payloadLen = 0) {
  uint8_t plain[6 + 32];
  if (payloadLen > 32) payloadLen = 32;
  plain[0] = cmd;
  plain[1] = result;
  plain[2] = counter >> 24; plain[3] = counter >> 16; plain[4] = counter >> 8; plain[5] = counter;
  if (payloadLen) memcpy(plain + 6, payload, payloadLen);
  size_t plainLen = 6 + payloadLen;

  uint8_t out[2 + 12 + sizeof(plain) + 16];
  out[0] = FRAME_SEALED_REPLY;
  out[1] = p->id;
  esp_fill_random(out + 2, 12);
  mbedtls_gcm_context g;
  mbedtls_gcm_init(&g);
  mbedtls_gcm_setkey(&g, MBEDTLS_CIPHER_ID_AES, p->key, 256);
  mbedtls_gcm_crypt_and_tag(&g, MBEDTLS_GCM_ENCRYPT, plainLen, out + 2, 12, &p->id, 1,
                            plain, out + 14, 16, out + 14 + plainLen);
  mbedtls_gcm_free(&g);
  sendFrame(out, 14 + plainLen + 16);
}

// Lenh: [0x02][keyId][IV 12][ban ma][tag 16]; ban ro = [cmd][counter 4B][nonce 8B][unixTime 4B][payload]
void handleSealed(const uint8_t *f, size_t n) {
  if (n < 2 + 12 + 17 + 16) { Serial.println("[BLE] Goi lenh qua ngan"); return; }
  Phone *p = findPhone(f[1]);
  if (!p) { Serial.printf("[BLE] keyId %u khong ton tai / da thu hoi\n", f[1]); return; }

  size_t ctLen = n - 2 - 12 - 16;
  uint8_t plain[64];
  if (ctLen > sizeof(plain)) return;
  mbedtls_gcm_context g;
  mbedtls_gcm_init(&g);
  mbedtls_gcm_setkey(&g, MBEDTLS_CIPHER_ID_AES, p->key, 256);
  int rc = mbedtls_gcm_auth_decrypt(&g, ctLen, f + 2, 12, f + 1, 1, f + n - 16, 16, f + 14, plain);
  mbedtls_gcm_free(&g);
  if (rc != 0) {
    Serial.println("[BLE] TU CHOI: sai tag GCM (goi bi sua hoac sai khoa)");
    return;
  }

  uint8_t cmd = plain[0];
  uint32_t counter = ((uint32_t)plain[1] << 24) | ((uint32_t)plain[2] << 16) | ((uint32_t)plain[3] << 8) | plain[4];
  bool nonceOk = nonceValid && millis() - nonceAt < NONCE_TTL_MS && memcmp(plain + 5, pendingNonce, 8) == 0;
  nonceValid = false;  // nonce chi dung 1 lan
  if (!nonceOk) {
    Serial.printf("[BLE] TU CHOI: nonce sai/het han (dien thoai #%u)\n", p->id);
    sendSealedReply(p, cmd, RES_BAD_NONCE, counter);
    return;
  }
  if (counter <= p->lastCounter) {
    Serial.printf("[BLE] TU CHOI: bo dem %lu <= %lu (nghi phat lai)\n", (unsigned long)counter, (unsigned long)p->lastCounter);
    sendSealedReply(p, cmd, RES_BAD_COUNTER, counter);
    return;
  }
  p->lastCounter = counter;  // giai doan 2: ghi NVS

  switch (cmd) {
    case CMD_UNLOCK:
      setRelay(true);
      unlockCount++;
      Serial.printf("[KHOA] MO bang app - dien thoai #%u, lan %lu\n", p->id, (unsigned long)unlockCount);
      sendSealedReply(p, cmd, RES_OK, counter);
      break;
    case CMD_LOCK:
      setRelay(false);
      Serial.println("[KHOA] DONG bang app");
      sendSealedReply(p, cmd, RES_OK, counter);
      break;
    case CMD_STATUS: {
      // payload: [relayOn 1B][uptime giay 4B][so lan mo 4B]
      uint32_t up = millis() / 1000;
      uint8_t st[9] = {(uint8_t)relayOn,
                       (uint8_t)(up >> 24), (uint8_t)(up >> 16), (uint8_t)(up >> 8), (uint8_t)up,
                       (uint8_t)(unlockCount >> 24), (uint8_t)(unlockCount >> 16), (uint8_t)(unlockCount >> 8), (uint8_t)unlockCount};
      sendSealedReply(p, cmd, RES_OK, counter, st, sizeof(st));
      break;
    }
    default:
      sendSealedReply(p, cmd, RES_UNKNOWN_CMD, counter);
  }
}

class CmdCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) override {
    String v = c->getValue();
    const uint8_t *f = (const uint8_t *)v.c_str();
    size_t n = v.length();
    if (n == 2 && f[0] == FRAME_CHALLENGE_REQ) {
      esp_fill_random(pendingNonce, sizeof(pendingNonce));
      nonceValid = true;
      nonceAt = millis();
      uint8_t out[9] = {FRAME_CHALLENGE};
      memcpy(out + 1, pendingNonce, 8);
      sendFrame(out, sizeof(out));
      Serial.printf("[BLE] Cap nonce cho keyId %u\n", f[1]);
    } else if (n > 0 && f[0] == FRAME_SEALED_CMD) {
      handleSealed(f, n);
    } else {
      Serial.printf("[BLE] Goi la (%u byte), bo qua\n", (unsigned)n);
    }
  }
};

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *s) override {
    clientConnected = true;
    Serial.println("[BLE] Dien thoai da ket noi");
  }
  void onDisconnect(BLEServer *s) override {
    clientConnected = false;
    nonceValid = false;
    Serial.println("[BLE] Mat ket noi - quang ba lai");
    BLEDevice::startAdvertising();
  }
};

void setup() {
  Serial.begin(115200);
  delay(300);
  pinMode(RELAY_PIN, OUTPUT);
  setRelay(false);
  Serial.println();
  Serial.println("=== KHOA BAO MAT - FIRMWARE GIAI DOAN 1 (BLE + RELAY) ===");

  BLEDevice::init(LOCK_BLE_NAME);
  BLEDevice::setMTU(247);
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  BLEService *service = server->createService(SERVICE_UUID);

  BLECharacteristic *cmdChar = service->createCharacteristic(CMD_UUID, BLECharacteristic::PROPERTY_WRITE);
  cmdChar->setCallbacks(new CmdCallbacks());
  evtChar = service->createCharacteristic(EVT_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  evtChar->addDescriptor(new BLE2902());
  service->start();

  BLEAdvertising *adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);  // app loc theo UUID nay khi quet
  adv->setScanResponse(true);         // ten "Khoabaomat" nam trong scan response
  BLEDevice::startAdvertising();
  Serial.printf("[BLE] Dang quang ba '%s', dia chi %s\n", LOCK_BLE_NAME, BLEDevice::getAddress().toString().c_str());
}

void loop() {
  if (relayOffAt && (int32_t)(millis() - relayOffAt) >= 0) {
    setRelay(false);
    Serial.println("[KHOA] Tu dong khoa lai");
  }
  delay(10);
}
```

> ⚠️ `phones[]` ở trên chỉ là dữ liệu demo (khóa toàn số 0). Phía app tương ứng là `lib/core/dev/demo_pairing.dart`. Bản thật tạo khóa lúc ghép đôi và lưu vào NVS bằng `Preferences`.
> Bộ đếm `lastCounter` cũng phải ghi vào NVS, nếu không thì khi khởi động lại, gói cũ có thể được phát lại.
>
> Cách thử nhanh không cần app: cài **nRF Connect** trên điện thoại, kết nối "Khoabaomat", rồi ghi `01 01` vào characteristic `…0002`.
> Khóa sẽ notify về `81` kèm 8 byte nonce.

---

## 7. Quy trình: quét khuôn mặt → mở khóa

### 7.1. Sơ đồ tuần tự

```
Người dùng          App Flutter                                    Khóa ESP32
    │                   │                                              │
    │ bấm "Mở cửa"      │                                              │
    │──────────────────►│ ① UnlockBloc → UnlockWithBiometric           │
    │                   │   Đã kết nối chưa? Nếu chưa: connect + SYNC_TIME│
    │                   │                                              │
    │ ◄── Face ID ──────│ ② local_auth.authenticate(biometricOnly)    │
    │ nhìn vào máy ────►│    (hoặc FaceNet + nháy mắt → biết memberId) │
    │                   │                                              │
    │                   │ ③ Đọc khóa AES + keyId từ secure storage    │
    │                   │    (chỉ đọc SAU khi xác thực thành công)     │
    │                   │                                              │
    │                   │ ④ ── [01][keyId] ───────────────────────────►│ sinh nonce 8B, hạn 10 giây
    │                   │ ◄──────────────────────── [81][nonce] ───────│
    │                   │                                              │
    │                   │ ⑤ counter++ ; gói = AES-GCM(                │
    │                   │      [10][counter][nonce][unixTime])         │
    │                   │ ── [02][keyId][IV][bản mã][tag] ────────────►│ ⑥ kiểm tra: tag GCM → nonce →
    │                   │                                              │    bộ đếm → quyền → khung giờ
    │                   │                                              │ ⑦ relay GPIO22 BẬT 5 giây
    │                   │                                              │    LED xanh, buzzer kêu 1 tiếng
    │                   │                                              │    ghi nhật ký (giờ, ai, "app-face")
    │                   │ ◄─────── [82][keyId][IV][AES(10,00,counter)] │
    │                   │ ⑧ giải mã, kiểm tra cmd và counter khớp      │
    │ ◄── "Đã mở cửa" ──│    → UnlockSucceeded                         │
    │                   │                                              │ ⑨ sau 5 giây: relay TẮT (tự khóa)
```

Thời gian ước tính (khi đã kết nối sẵn):

| Bước | Thời gian |
|---|---|
| Quét Face ID / vân tay | ~0,5–1 giây |
| Hai lượt BLE (challenge và lệnh) | ~0,1–0,3 giây |

Nếu chưa kết nối, cộng thêm khoảng 1–2 giây.

### 7.2. Biến thể FaceNet (chế độ máy dùng chung)

Bước ② thay bằng màn quét của **faceid**:
1. Mở `FaceScanScreen`, kiểm tra nháy mắt (mắt mở → nhắm → mở).
2. Chụp 2 ảnh, tạo vector 512 chiều bằng FaceNet-512.
3. So với vector của từng thành viên. Khoảng cách nhỏ nhất ≤ **0,65** (mức "Cao" của faceid) thì nhận ra `memberId`.
4. Mỗi thành viên có `keyId` riêng trên khóa, nên nhật ký sẽ ghi đúng người.

Sai 3 lần thì bắt buộc dùng PIN.

### 7.3. Xử lý lỗi

| Tình huống | Phát hiện ở | App hiển thị | Hành động |
|---|---|---|---|
| Người dùng hủy Face ID | `BiometricOutcome.canceled` | "Đã hủy xác thực" | Không gửi gì |
| Máy chưa cài sinh trắc học | `notEnrolled` | Hướng dẫn vào Cài đặt | Gợi ý dùng PIN |
| Sinh trắc bị khóa tạm do sai nhiều | `lockedOut` | "Sai quá nhiều lần" | Dùng PIN màn hình khóa của máy để mở lại |
| Khóa không trả lời trong 5 giây | `TimeoutException` | "Hãy lại gần cửa hơn" | Tự kết nối lại 1 lần, rồi thử lại |
| Nonce hết hạn (người dùng chần chừ) | Kết quả `0x01` | "Phiên đã hết hạn" | Tự xin nonce mới và gửi lại 1 lần |
| Bộ đếm lệch (khôi phục từ bản sao lưu) | Kết quả `0x02` | "Gói tin bị phát lại" | Gửi `STATUS` để lấy bộ đếm hiện tại của khóa |
| Điện thoại bị thu hồi | Kết quả `0x03` | "Không còn quyền mở" | Xóa khóa AES trên máy |
| Phản hồi bị sửa | `SecretBoxAuthenticationError` | "Phản hồi bị sửa đổi" | Ngắt kết nối, ghi cảnh báo |
| Mất kết nối giữa chừng | `BleException` / `connectionState` | "Mất kết nối" | Không lặp lại tự động: bạn kiểm tra cửa đã mở hay chưa bằng `STATUS` |

---

## 8. Các tính năng phụ trợ trên phần cứng thật

### 8.1. Quản lý thiết bị
- **Quét / kết nối**: xem mục 6.2. Danh sách khóa đã ghép đôi lưu trong drift (`lockId`, tên, `keyId`, lần kết nối cuối).
- **Đổi tên**: tên hiển thị lưu trong app. Nếu muốn đổi cả tên quảng bá BLE thì thêm lệnh `SET_NAME`, khóa lưu tên vào NVS rồi khởi động lại phần BLE.
- **Pin / nguồn**: khóa hiện chạy bằng **adapter 12V**, không có pin, nên app hiển thị "Nguồn: adapter" kèm RSSI (độ mạnh sóng).
  - Nếu sau này thêm pin dự phòng, nối cầu chia áp vào một chân ADC còn trống là **GPIO35, 36 hoặc 39** (chỉ đọc, thuộc ADC1, dùng được khi đang bật BLE). Khóa sẽ báo điện áp trong `STATUS`.

### 8.2. Nhật ký ra vào
- Mỗi bản ghi 16 byte, gồm:

  | Trường | Kích thước |
  |---|---|
  | `unixTime` | 4 byte |
  | `phương thức` (app-face, app-fp, RFID, vân tay khóa, PIN, khách TOTP, nút trong nhà) | 1 byte |
  | `memberId` | 1 byte |
  | `kết quả` (mở / sai / khóa tạm) | 1 byte |
  | `dữ liệu thêm` (vd. 4 byte cuối UID thẻ lạ) | 9 byte |

- Khóa lưu theo **vòng 2000 bản ghi** trong LittleFS (32 KB). Bản ghi mới đè lên bản ghi cũ nhất.
- App gửi `GET_LOGS` kèm chỉ số cuối cùng đã có. Khóa trả các bản ghi mới qua characteristic Log, mỗi gói tối đa 15 bản ghi (240 byte). App lưu vào drift, lọc theo người, phương thức, ngày.

### 8.3. Thành viên và phân quyền

| Vai trò | Mở cửa | Quản lý thẻ / vân tay / PIN | Xem nhật ký | Thu hồi người khác |
|---|---|---|---|---|
| admin | ✓ | ✓ | ✓ | ✓ |
| member | ✓ | Chỉ của mình | Chỉ của mình | ✗ |
| guest | Chỉ trong khung giờ | ✗ | ✗ | ✗ |

Khóa lưu ánh xạ của từng thành viên: điện thoại (`keyId`), thẻ RFID (UID), vân tay AS608 (ID) và PIN đều trỏ về `memberId`. App lưu tên và ảnh đại diện.

### 8.4. Mã PIN và mã khách
- **PIN thành viên**: 4–8 số, gõ trên bàn phím rồi bấm `#` để xác nhận, `*` để xóa. Khóa chỉ lưu `SHA-256(salt + PIN)`.
- **Mã khách theo thời gian (TOTP)**:
  - App dùng gói `otp` tạo secret rồi gửi `ADD_GUEST_TOTP` kèm khung giờ hiệu lực.
  - App tính mã 6 số hiện tại để chia sẻ cho khách. Mã đổi mỗi 30 giây, khóa chấp nhận lệch ±1 bước.
  - Mã một lần: khóa đánh dấu đã dùng ngay sau lần mở đầu tiên.

### 8.5. Thẻ RFID
- App gửi `ENROLL_RFID` kèm `memberId`. Khóa chờ quẹt thẻ trong 15 giây (LED nháy), đọc UID bằng code đã test trong `rfid_test.ino`, lưu UID vào NVS rồi trả UID về cho app.
- Đã đọc thử 2 thẻ: `D0:43:46:5E` và `99:64:F2:E6` (MIFARE 1KB).

### 8.6. Vân tay trên khóa (AS608)
- App gửi `ENROLL_FINGER` kèm `memberId`. Khóa chọn ID trống (1–300) rồi gửi tiến trình qua Event:
  1. "Đặt ngón tay"
  2. "Nhấc ra"
  3. "Đặt lại lần 2"
  4. "Đã lưu ID #n"

  Phía khóa dùng các lệnh `getImage` → `image2Tz(1)` → `getImage` → `image2Tz(2)` → `createModel` → `storeModel(id)` của thư viện Adafruit Fingerprint.
- AS608 đã test: 57600 baud, lưu được 300 mẫu, mức bảo mật 3, hiện chưa có mẫu nào.

---

## 9. Lộ trình triển khai

| Giai đoạn | Nội dung | Kết quả kiểm tra được |
|---|---|---|
| **0** ✅ | Đấu dây, test từng phần cứng | RC522, bàn phím, AS608 chạy đúng (đã xong) |
| **1** ✅ | Firmware: BLE server + AES-GCM + relay (mục 6.12). App: quét, kết nối, trạng thái, mở cửa (sinh trắc học), khóa ngay | Đã kiểm tra: firmware 10/10 bài test BLE; integration test của app với ESP32 thật qua; build được APK và bản Windows |
| **2** | Ghép đôi X25519 + mã 6 số; mở khóa bằng `local_auth` + AES-GCM | Mở được cửa bằng Face ID / vân tay; gói phát lại bị từ chối |
| **3** | Firmware gộp RFID, bàn phím (PIN), AS608, nút; nhật ký LittleFS; đồng bộ giờ | Mở bằng cả 5 cách; app xem được nhật ký |
| **4** | App: thành viên, vai trò, đăng ký thẻ / vân tay / PIN từ app, mã khách TOTP | Admin thêm khách, khách mở đúng khung giờ |
| **5** | Chế độ FaceNet (chép từ faceid), hoàn thiện giao diện sáng/tối, build iOS (cần Mac) | Nhận đúng người trên máy dùng chung |
| **6** | Bảo mật nâng cao: khóa bọc bằng Keystore (BiometricLock của faceid), khóa bàn phím khi dò PIN, Flash Encryption trên board cuối | Rà lại toàn bộ bảng rủi ro ở mục 5.4 |

---

## 10. Kiểm thử

| Mức | Công cụ | Nội dung |
|---|---|---|
| Unit | `flutter_test` | `LockCrypto`: ghép đôi 2 phía ra cùng khóa và cùng mã; mã hóa/giải mã đúng từng trường; sửa 1 bit hoặc đổi keyId thì bị từ chối (**đã có, 3 test**). `LockStatus` đọc đúng payload (**1 test**) |
| Widget | `flutter_test` | Màn "Tìm khóa" ở 360 dp, sáng và tối, không tràn bố cục (**đã có, 2 test**) |
| Bloc | `bloc_test` + `mocktail` | `UnlockBloc`: thứ tự trạng thái khi mở thành công / bị hủy (**đã có, 2 test**). Viết thêm cho scan, pairing, logs |
| Use case | `mocktail` | Giả lập `BleLockDataSource` trả timeout, nonce sai, phản hồi bị sửa để kiểm tra từng dòng của bảng 7.3 |
| Tương thích giao thức | Test chéo Dart ↔ ESP32 | Dùng một bộ vector cố định (khóa, IV, bản rõ → bản mã + tag) chạy ở cả 2 phía, đảm bảo GCM ra cùng kết quả |
| Phần cứng | Serial 115200 (COM3), các sketch `*_test` | Đã test RFID, bàn phím, AS608; còn relay, LED, buzzer, nút |
| Tích hợp BLE | `integration_test` + ESP32 thật | Quét → kết nối → STATUS → MỞ → STATUS → KHÓA (**đã có, chạy qua trên Windows**): `flutter test integration_test/ble_lock_test.dart -d windows` |
| Firmware qua BLE | Script Python `bleak` đóng vai điện thoại | 10 bài: quét, kết nối, nonce, mở, trạng thái, phát lại (`0x01`), bộ đếm cũ (`0x02`), sửa 1 bit, sai khóa, tự khóa sau 5 giây (**10/10 qua**) |
| Điện thoại thật | nRF Connect / app | Kết nối, MTU, notify, mất kết nối, 2 điện thoại tranh nhau |
| Bảo mật | nRF Connect / sniffer | Ghi lại gói hợp lệ rồi phát lại → phải bị từ chối với mã `0x01` hoặc `0x02` |
| Giao diện | `flutter test` (widget) | Màn hình 360 dp, sáng/tối, chữ tiếng Việt không bị tràn |

**Lệnh hay dùng:**

```bash
flutter analyze
flutter test
flutter test integration_test/ble_lock_test.dart -d windows   # cần ESP32 đang chạy firmware/smart_lock
flutter run                      # điện thoại Android cắm USB, bật gỡ lỗi USB
flutter build apk --debug        # file APK: build/app/outputs/flutter-apk/app-debug.apk
arduino-cli compile --fqbn esp32:esp32:esp32:PartitionScheme=huge_app firmware/smart_lock
arduino-cli upload  --fqbn esp32:esp32:esp32:PartitionScheme=huge_app -p COM3 firmware/smart_lock
arduino-cli monitor -p COM3 -c baudrate=115200
```
