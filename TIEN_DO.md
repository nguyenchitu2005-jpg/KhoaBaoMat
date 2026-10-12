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
| 3 | RFID, PIN, vân tay, nút trong nhà, nhật ký, lệnh quản lý, trang app | 🟡 Đang làm (firmware khoảng 40%) |
| 4 | Thành viên, mã khách TOTP | ⬜ Chưa làm |

---

## 2. Môi trường và công cụ (giai đoạn 0)

| Thành phần | Phiên bản / ghi chú |
|---|---|
| arduino-cli | 1.5.1 |
| Lõi ESP32 | esp32:esp32 3.3.12. FQBN `esp32:esp32:esp32:PartitionScheme=huge_app` |
| Driver USB | CP210x 11.5.0.417 (chip CP2102), cổng **COM3** |
| ESP32 | ESP32-D0WD-V3, không có PSRAM, MAC `b0:3f:d3:7c:60:64` |
| Flutter / Dart | 3.47.3 / 3.13.3 |
| Gói Flutter chính | flutter_blue_plus 2.3.14, local_auth 3.0.2, flutter_secure_storage 11.2.0, cryptography 2.9.0, flutter_bloc 9.1.1, equatable 3.0.0, get_it 9.3.0 |
| Gói test | bloc_test, mocktail, integration_test |

Lệnh nạp firmware:

```bash
arduino-cli compile --fqbn esp32:esp32:esp32:PartitionScheme=huge_app --upload -p COM3 firmware/smart_lock
```

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

### Còn phải làm
1. **Viết lại `smart_lock.ino`** để tích hợp các phần mới:
   - Đọc thẻ RFID: thẻ đã đăng ký thì mở cửa; thẻ lạ thì nháy LED đỏ và ghi UID vào nhật ký.
   - Vân tay: dò mỗi 300 ms.
   - PIN trên bàn phím: bấm `#` để gửi, `*` để xoá. Sai 5 lần thì khoá bàn phím 5 phút.
   - Ghi nhật ký cho mọi lần mở (app, thẻ, vân tay, PIN, nút).
   - Đồng bộ giờ từ mỗi lệnh mã hoá.
   - Lệnh quản lý chỉ dành cho admin: đăng ký/xoá thẻ, đăng ký vân tay (đặt tay 2 lần)/xoá vân tay, đặt PIN, liệt kê, đọc nhật ký.
2. **Test bằng Python trên laptop** (laptop là admin). Bạn sẽ cần quẹt thẻ, đặt vân tay và gõ PIN.
3. **App**:
   - Thêm tham số timeout cho `SecureCommandSender.send` (lệnh đăng ký phải chờ tới 30 giây).
   - Trang **Quản lý truy cập**: thẻ, vân tay, PIN.
   - Trang **Nhật ký**.
   - Unit test và test trên điện thoại.
4. Để dùng trang quản lý, **điện thoại phải là admin**. Cần giữ nút BOOT 15 giây để xoá hết thiết bị, rồi ghép đôi điện thoại trước tiên.

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
    smart_lock.ino    vòng lặp chính (đang là bản giai đoạn 2)
  rfid_test/, keypad_test/, fingerprint_test/, fingerprint_diag/,
  hardware_test/, button_diag/      các sketch kiểm tra phần cứng
lib/
  core/ble/           lock_protocol.dart, secure_command_sender.dart
  core/crypto/        lock_crypto.dart
  core/storage/       lock_key_store.dart
  core/di/            injection.dart
  core/theme/         app_theme.dart
  features/device/    quét, kết nối, ghép đôi, trạng thái
  features/unlock/    mở khoá bằng sinh trắc học
  features/biometric/ local_auth
test/                 lock_crypto_test, unlock_bloc_test, scan_page_test (9/9 đạt)
integration_test/     ble_lock_test.dart (chạy với ESP32 thật)
```

**Chạy test app**

```bash
flutter analyze
flutter test
flutter test integration_test/ble_lock_test.dart -d <thiết bị>
```
