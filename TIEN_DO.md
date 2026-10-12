# Tiến độ dự án Khoá bảo mật (ESP32 + App Flutter)

*Cập nhật: 12/10/2026*

Tài liệu liên quan:
- [SO_DO_NOI_DAY.md](SO_DO_NOI_DAY.md): sơ đồ nối dây và bảng GPIO.
- [KIEN_TRUC_APP.md](KIEN_TRUC_APP.md): kiến trúc app và giao thức BLE. Tài liệu này mới cập nhật tới giai đoạn 1.

---

## 1. Tóm tắt

| Giai đoạn | Nội dung | Trạng thái |
|---|---|---|
| 0 | Cài công cụ, driver, kiểm tra từng linh kiện | ✅ Xong |
| 1 | BLE + relay + app quét, kết nối, mở khoá | ✅ Xong, đã test trên laptop và điện thoại |
| 2 | Ghép đôi an toàn (X25519 + mã 6 số trên bàn phím) | ✅ Xong, đã test trên laptop và điện thoại |
| 3 | RFID, PIN, vân tay, nút trong nhà, nhật ký, lệnh quản lý, trang app | 🟡 Đã nạp và test trên khoá thật: ghép đôi, PIN, vân tay, thẻ đều đạt. Còn vài mục chưa thử (xem mục 6) |
| 4 | Thành viên, mã khách TOTP | ⬜ Chưa làm |

---

## 2. Môi trường và công cụ (giai đoạn 0)

| Thành phần | Phiên bản / ghi chú |
|---|---|
| arduino-cli | 1.5.1 |
| Lõi ESP32 | esp32:esp32 3.3.12. FQBN `esp32:esp32:esp32:PartitionScheme=huge_app` |
| Driver USB | CP210x 11.5.0.417 (chip CP2102), cổng **COM5** |
| ESP32 | ESP32-D0WD-V3, không có PSRAM, MAC `b0:3f:d3:7c:60:64` |
| Flutter / Dart | 3.47.3 / 3.13.3 |
| Gói Flutter chính | flutter_blue_plus 2.3.14, local_auth 3.0.2, flutter_secure_storage 11.2.0, cryptography 2.9.0, flutter_bloc 9.1.1, equatable 3.0.0, get_it 9.3.0 |
| Gói test | bloc_test, mocktail, integration_test |

Bộ công cụ ESP32 nằm ở `D:\arduino-data` (ổ C không đủ chỗ), dùng `arduino-cli` 1.3.1 đi kèm Arduino IDE. Thư viện: MFRC522 1.4.12, Adafruit Fingerprint Sensor Library 2.1.4.

Lệnh nạp firmware (PowerShell):

```powershell
$env:ARDUINO_DIRECTORIES_DATA = "D:\arduino-data\data"
$env:ARDUINO_DIRECTORIES_DOWNLOADS = "D:\arduino-data\staging"
$env:ARDUINO_DIRECTORIES_USER = "D:\arduino-data\user"
$cli = "$env:LOCALAPPDATA\Programs\Arduino IDE\resources\app\lib\backend\resources\arduino-cli.exe"
& $cli compile --fqbn esp32:esp32:esp32:PartitionScheme=huge_app --build-path D:\arduino-data\build\smart_lock --upload -p COM5 firmware/smart_lock
```

Cổng hiện là **COM5** (sau khi cài lại driver CP210x 11.5.0.417 từ Microsoft Update Catalog; bản lưu ở `D:\arduino-data\cp210x`).

Build và cài app lên điện thoại (biến `ANDROID_HOME` của máy trỏ sai, phải đặt lại trong phiên):

```powershell
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
flutter build apk --release
& "$env:ANDROID_HOME\platform-tools\adb.exe" install -r build\app\outputs\flutter-apk\app-release.apk
```

Điện thoại OPPO phải bật "Cài đặt qua USB" trong Tuỳ chọn nhà phát triển, nếu không adb báo `Failure [-99]`.

---

## 3. Kiểm tra phần cứng

| Linh kiện | Chân | Kết quả | Ghi chú |
|---|---|---|---|
| RFID RC522 | SS 5, SCK 18, MISO 19, MOSI 23, RST 4 | ✅ Đọc được UID thẻ | `firmware/rfid_test` |
| Bàn phím 4×4 | Hàng 13, 14, 27, 26 · Cột 25, 33, 32, 21 | ✅ Đủ 16 phím | Đã đổi lại dây cột C1 và C4 bị lộn. `firmware/keypad_test` |
| Vân tay AS608 | UART2 RX 16 / TX 17, 57600 baud | ✅ Đọc và so khớp được | Đã cắm lại dây RX bị lỏng. `firmware/fingerprint_test`, `fingerprint_diag` |
| Relay | GPIO22, jumper H (kích mức cao) | ✅ Đóng/ngắt được | **Chưa thử với khoá 12V** |
| LED xanh / đỏ | GPIO2 / GPIO15 | ⚠️ Chưa xác nhận bằng mắt | |
| Còi | GPIO12 | ⚠️ Chưa xác nhận | |
| Nút trong nhà | GPIO34 | ⚠️ Chân bị thả nổi vì chưa có điện trở kéo lên | Tạm dùng **nút BOOT (GPIO0)**. Firmware tự chọn nút. `firmware/button_diag` |
| Nguồn 12V + LM2596S | | ⚠️ Chưa cắm 12V | |

Bản test tổng hợp `firmware/hardware_test` có bảo vệ relay: đóng tối đa 3 giây, nghỉ 5 giây. Nút bị tự tắt nếu chân thả nổi.

---

## 4. Giai đoạn 1: BLE và mở khoá ✅

**Firmware**
- BLE GATT server tên `Khoabaomat`, MTU 247.
- Service `8a1c0001-…`, characteristic Command `…0002` (write) và Event `…0003` (notify).
- Chống phát lại (replay): app xin nonce 8 byte (hết hạn sau 10 giây, chỉ dùng 1 lần) rồi gửi lệnh mã hoá AES-256-GCM kèm bộ đếm tăng dần. Bộ đếm được lưu trong NVS.
- Lệnh `UNLOCK` (0x10): relay đóng 5 giây rồi tự khoá lại. Ngoài ra có `LOCK` (0x11) và `STATUS` (0x12).

**App** (Clean Architecture + Bloc, DI bằng get_it)
- Trang **Tìm khoá**: quét BLE, lọc theo service UUID.
- Trang **Thiết bị**: kết nối, xem trạng thái, khoá ngay.
- Nút **Mở khoá**: xác thực sinh trắc học (local_auth) trước khi gửi lệnh mã hoá.

**Kết quả test**
- Python (bleak): 10/10.
- Integration test trên Windows và điện thoại Android: đạt.

---

## 5. Giai đoạn 2: Ghép đôi an toàn ✅

**Quy trình**
1. Giữ nút trong nhà (tạm thời là nút BOOT) **5 giây**. LED xanh nhấp nháy, khoá mở cửa sổ ghép đôi 60 giây.
2. App gửi khoá công khai X25519. Khoá trả về khoá công khai của nó kèm `keyId`.
3. Hai bên cùng tính khoá AES riêng cho điện thoại bằng HKDF-SHA256 (salt `khoabaomat-v1`), và tính ra một **mã 6 số**.
4. Người dùng gõ mã 6 số hiện trên app vào bàn phím của khoá. Khoá tự xác nhận khi đủ 6 số (cũng có thể bấm `#`). Bấm `*` để xoá. Sai 3 lần thì huỷ.

**Quy tắc**
- Điện thoại ghép đôi đầu tiên là **admin**, các máy sau là thành viên. Tối đa 8 điện thoại.
- Giữ nút **15 giây** sẽ xoá hết điện thoại đã ghép.
- Bấm nhanh nút trong nhà sẽ mở cửa.

**App**
- Trang **Ghép đôi**: hiện mã 6 số cỡ lớn.
- Menu "Bỏ ghép đôi trên máy này".
- Khoá AES lưu trong `flutter_secure_storage`.

**Kết quả test**
- Python: ghép đôi 7/7, kiểm tra khoá vẫn hoạt động sau khi khởi động lại 2/2.
- Điện thoại: ghép đôi thành công (là máy #2, thành viên) và mở khoá được.
- Vector test chung giữa C (mbedtls), Python và Dart khớp nhau (`test/lock_crypto_test.dart`).

**Trạng thái khoá hiện tại**: đã ghép 2 thiết bị.
- Laptop là #1 (admin). Khoá lưu ở `pair_state.json` trong scratchpad.
- Điện thoại là #2 (thành viên).

---

## 6. Giai đoạn 3: Các cách mở khoá khác và quản lý 🟡

### Đã xong
- [config.h](firmware/smart_lock/config.h): đã thêm chân RFID/AS608, giới hạn bộ nhớ, mã lệnh, mã kết quả và mã nhật ký:
  - Giới hạn: 20 thẻ, 32 vân tay, 500 bản ghi nhật ký.
  - Mã lệnh: `GET_LOGS` 0x20, `ENROLL_CARD` 0x30, `DELETE_CARD` 0x31, `ENROLL_FINGER` 0x32, `DELETE_FINGER` 0x33, `SET_PIN` 0x34, `LIST_ACCESS` 0x36.
  - Thêm mã kết quả và mã phương thức/kết quả cho nhật ký.
- [access_store.h](firmware/smart_lock/access_store.h): lưu quyền truy cập trong NVS.
  - Danh sách thẻ RFID.
  - Mặt nạ (bitmask) ID vân tay.
  - Mã PIN: chỉ lưu **SHA-256(salt ngẫu nhiên + PIN)** và so sánh không phụ thuộc thời gian.
- [access_log.h](firmware/smart_lock/access_log.h): nhật ký ra vào.
  - Bộ đệm vòng 500 bản ghi × 16 byte trong LittleFS (`/log.bin`).
  - Giờ thật được đồng bộ từ lệnh của app. Khi chưa đồng bộ thì ghi số giây kể từ lúc khởi động.

- [smart_lock.ino](firmware/smart_lock/smart_lock.ino) (12/10/2026, biên dịch đạt: 1.223.826 byte = 38% flash, RAM 13%):
  - Thẻ RFID: thẻ đã đăng ký thì mở cửa; thẻ lạ thì nháy LED đỏ và ghi UID vào nhật ký.
  - Vân tay: dò mỗi 300 ms (`FP_POLL_MS`). Thẻ dò mỗi 100 ms (`RFID_POLL_MS`). Tạm ngừng dò khi đang gõ bàn phím.
  - PIN: gõ rồi bấm `#`, `*` để xoá. Sai 5 lần thì khoá bàn phím 5 phút (bộ đếm sai chỉ nằm trong RAM).
  - Ghi nhật ký mọi lần mở và thử sai. Đồng bộ giờ từ mỗi lệnh mã hoá.
  - Lệnh từ `0x20` trở lên chỉ dành cho admin, máy khác nhận `0x03`.
  - Đăng ký vân tay gửi thêm gói tiến trình không mã hoá `[0x86][cmd][bước]` (1 = nhấc tay, 2 = đặt lại).
  - `STATUS` trả thêm 2 byte: vai trò (1 = admin) và bàn phím có đang bị khoá không.
  - `GET_LOGS` trả `[tổng 4B][bản ghi đầu 4B][số bản ghi][bản ghi 16B…]`, tối đa 12 bản ghi mỗi lần. Thời gian trong bản ghi là little-endian.
  - **Giữ nút 15 giây giờ xoá cả thẻ, vân tay và PIN**, không chỉ điện thoại. Nhật ký được giữ lại.
- App:
  - `SecureCommandSender.send` có tham số `timeout`.
  - `lib/features/access/`: `AccessAdmin` (lệnh quản lý), trang **Quản lý truy cập** (PIN, thẻ, vân tay), trang **Nhật ký** (60 bản ghi mới nhất).
  - Trang Thiết bị hiện 2 mục này khi điện thoại là admin; phải qua sinh trắc học mới mở được.
  - `test/access_admin_test.dart`. Tổng 14/14 test đạt, `flutter analyze` sạch.

### Kết quả test trên khoá thật (12/10/2026, điện thoại OPPO PKB110 là admin #1)
- ✅ Xoá hết bằng giữ nút 15 giây, ghép đôi lại, điện thoại là admin.
- ✅ Đặt PIN từ app, gõ PIN đúng + `#` thì mở. Lần đầu không chạy vì lỗi tràn số khi tính "10 giây không bấm thì xoá" (so `now` cũ với `pinLastKey` mới hơn); đã sửa.
- ✅ Đăng ký vân tay (2 lần đặt tay) và mở bằng vân tay.
- ✅ Thẻ lạ bị từ chối, đăng ký thẻ, mở bằng thẻ.
- ⬜ Chưa thử: gõ sai PIN và khoá bàn phím sau 5 lần sai; mở khoá từ app sau lần nạp cuối; trang Nhật ký; xoá thẻ / vân tay / tắt PIN.

### Còn phải làm
1. Thử nốt các mục ⬜ ở trên.
2. Nếu bàn phím bị sót phím đầu tiên, tăng `FP_POLL_MS` / `RFID_POLL_MS` trong `config.h`.
3. Cập nhật `KIEN_TRUC_APP.md` (mục 4 vẫn là giao thức dự kiến của giai đoạn 1).

Khoá của laptop (`pair_state.json`) và script test Python đã mất cùng thư mục tạm, nên giờ chỉ test qua điện thoại.

---

## 7. Lỗi đã gặp và cách xử lý

| Vấn đề | Cách xử lý |
|---|---|
| Không tải được driver CP210x từ trang Silabs | Lấy từ Microsoft Update Catalog, cài bằng `pnputil` |
| Build Windows lỗi STL1011 (local_auth_windows) | Thêm `_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS` vào `windows/CMakeLists.txt` |
| App Windows kết nối nhầm thiết bị BLE khác | Lọc thêm theo service UUID ở phía Dart |
| `permission_handler` đòi compileSdk 37 | Bỏ gói này. flutter_blue_plus tự xin quyền |
| Kotlin báo "Could not close incremental caches" (project ở ổ D:, cache ở ổ C:) | Thêm `kotlin.incremental=false` vào `android/gradle.properties` |
| Bàn phím ra sai ký tự (bấm 1 ra A) | Đổi lại dây cột C1 và C4 |
| AS608 không phản hồi | Cắm lại dây RX |
| Nút GPIO34 tự kích (chân thả nổi, đo được 142–3165 mV) | Tạm dùng nút BOOT, firmware tự phát hiện. Relay có giới hạn thời gian đóng |
| Log ngắt kết nối BLE lặp liên tục (khoảng 740 dòng/giây) | Giới hạn 1 dòng/giây, dùng `advertiseOnDisconnect(true)` |
| Ghép đôi bị hết giờ vì người dùng không bấm `#` | Tự xác nhận khi gõ đủ 6 số |

---

## 8. Việc phần cứng còn tồn đọng

- [ ] Gắn **điện trở kéo lên 10k** (dùng được trong khoảng 1k–100k) giữa GPIO34 và 3.3V cho nút trong nhà. **Không** được thay điện trở bằng dây điện vì sẽ gây chập.
- [ ] Chỉnh LM2596S ra **đúng 5.0V** trước khi nối vào mạch.
- [ ] Nối khoá 12V: +12V vào COM của relay, NO nối về cực + của khoá, NC để trống. Sau đó test relay có tải.
- [ ] Rút nguồn 12V khi nạp firmware qua USB.
- [ ] Xác nhận LED xanh, LED đỏ và còi hoạt động.

---

## 9. Cấu trúc mã nguồn

```
firmware/
  smart_lock/         firmware chính
    config.h          chân GPIO, thời gian, mã lệnh
    crypto_util.h     AES-GCM, X25519, HKDF (mbedtls)
    storage.h         danh sách điện thoại đã ghép (NVS)
    access_store.h    thẻ / vân tay / PIN (giai đoạn 3)
    access_log.h      nhật ký LittleFS (giai đoạn 3)
    smart_lock.ino    vòng lặp chính (bản giai đoạn 3)
  rfid_test/, keypad_test/, fingerprint_test/, fingerprint_diag/,
  hardware_test/, button_diag/      các sketch kiểm tra phần cứng
lib/
  core/ble/           lock_protocol.dart, secure_command_sender.dart
  core/crypto/        lock_crypto.dart
  core/storage/       lock_key_store.dart
  core/di/            injection.dart
  core/theme/         app_theme.dart
  features/device/    quét, kết nối, ghép đôi, trạng thái
  features/access/    quản lý thẻ / vân tay / PIN, nhật ký (admin)
  features/unlock/    mở khoá bằng sinh trắc học
  features/biometric/ local_auth
test/                 lock_crypto_test, unlock_bloc_test, scan_page_test, access_admin_test (14/14 đạt)
integration_test/     ble_lock_test.dart (chạy với ESP32 thật)
```

**Chạy test app**

```bash
flutter analyze
flutter test
flutter test integration_test/ble_lock_test.dart -d <thiết bị>
```
