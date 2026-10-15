# KhoaBaoMat – Khoá cửa thông minh ESP32 + App Android

Khoá cửa chạy trên ESP32, mở được bằng **điện thoại** (vân tay hoặc khuôn mặt), **thẻ RFID**, **vân tay** trên khoá, **mã PIN**, hoặc **nút trong nhà**. Điện thoại nói chuyện với khoá qua Bluetooth. Khi khoá có Wi-Fi thì điều khiển được thêm qua mạng trong nhà và **từ xa** qua Internet. Mọi lệnh đều được mã hoá AES-256-GCM và chống phát lại (replay).

<p align="center"><b>📱 <a href="release/Khoabaomat.apk">Tải app Android (APK, 89 MB)</a></b> · Android 7.0 trở lên, máy 64-bit</p>

Mục lục:
1. [Tính năng](#1-tính-năng)
2. [Phần cứng](#2-phần-cứng)
3. [Cài firmware cho ESP32](#3-cài-firmware-cho-esp32)
4. [Cài app trên điện thoại](#4-cài-app-trên-điện-thoại)
5. [Hướng dẫn sử dụng](#5-hướng-dẫn-sử-dụng)
6. [Xử lý sự cố](#6-xử-lý-sự-cố)
7. [Dành cho lập trình viên](#7-dành-cho-lập-trình-viên)

---

## 1. Tính năng

| Cách mở cửa | Ghi chú |
|---|---|
| App trên điện thoại | Xác thực bằng vân tay/khuôn mặt của máy, hoặc quét khuôn mặt trong app (có kiểm tra nháy mắt) |
| Thẻ RFID 13,56 MHz | Tối đa 20 thẻ |
| Vân tay trên khoá (AS608) | Tối đa 32 vân tay |
| Mã PIN trên bàn phím | 4–8 số. Sai 5 lần thì bàn phím bị khoá 5 phút |
| Mã khách | Mã PIN tạm, tự hết hạn sau thời gian bạn chọn |
| Nút trong nhà | Bấm để mở, bấm lần nữa để khoá |

**Quản lý (chỉ điện thoại admin):**
- Thêm/xoá thẻ, vân tay, PIN, mã khách.
- Xem và thu hồi điện thoại đã ghép đôi.
- Xem nhật ký ra vào.
- Cài Wi-Fi cho khoá.
- Bật điều khiển từ xa.

**Ba đường kết nối**, app tự chọn đường tốt nhất:
1. Wi-Fi trong nhà (LAN), khi điện thoại và khoá cùng mạng.
2. Máy chủ trung gian MQTT (từ xa), khi khoá đang online.
3. Bluetooth, khi đứng gần khoá.

---

## 2. Phần cứng

| Linh kiện | Số lượng |
|---|---|
| ESP32 DevKit V1 (chip USB CP2102) + đế ra chân | 1 |
| Đầu đọc RFID RC522 + thẻ/móc khoá 13,56 MHz | 1 |
| Cảm biến vân tay AS608 | 1 |
| Bàn phím màng 4×4 | 1 |
| Module relay 1 kênh 5V (có jumper H/L) | 1 |
| Chốt khoá điện 12V + diode 1N4007 | 1 |
| Hạ áp LM2596S, adapter 12V 2A, jack DC cái | 1 |
| LED xanh, LED đỏ (mỗi đèn kèm trở 220Ω), còi | 1 bộ |
| Nút nhấn hoặc switch phím cơ + **điện trở 10kΩ** | 1 |

**Sơ đồ nối dây chi tiết** (danh sách 40 dây và bảng GPIO): xem [SO_DO_NOI_DAY.md](SO_DO_NOI_DAY.md).

| Thiết bị | Chân ESP32 |
|---|---|
| RC522 | SDA 5, SCK 18, MOSI 23, MISO 19, RST 4, nguồn **3,3V** |
| AS608 | TX của cảm biến → **16**, RX của cảm biến → **17**, nguồn 3,3V |
| Bàn phím | Hàng R1–R4 → 13, 14, 27, 26 · Cột C1–C4 → 25, 33, 32, 21 |
| Relay IN | 22 (jumper **H**) |
| LED xanh / LED đỏ / còi | 2 / 15 / 12 |
| Nút trong nhà | 34 |

> ⚠️ **Những điều phải nhớ khi nối dây**
> - **Jumper JUMP trên đế phải ở 3V3.** RC522 và chân 34 sẽ hỏng nếu nhận 5V.
> - **Nút trong nhà nối như sau:** 3,3V → điện trở 10k → chân A của nút; chân A nối thêm vào S của hàng 34; chân B của nút → GND. Nếu nối thẳng 3,3V vào nút mà không qua điện trở, mỗi lần nhấn sẽ **chập nguồn** và mạch tắt.
> - **Chỉnh LM2596S ra đúng 5,0V** (đo bằng đồng hồ) **trước** khi nối vào đế.
> - Mạch 12V: +12V → COM của relay, NO → cực + của khoá, NC để trống. Diode 1N4007 mắc song song hai cực của khoá, **vạch trắng về phía +**.
> - **Rút adapter 12V khi cắm USB** để nạp code hoặc xem log.

---

## 3. Cài firmware cho ESP32

Làm một lần trên máy tính Windows.

### 3.1. Driver USB
1. Cắm ESP32 vào máy tính bằng **cáp có truyền dữ liệu** (không dùng cáp chỉ để sạc).
2. Mở **Device Manager → Ports (COM & LPT)**.
   - Nếu thấy **Silicon Labs CP210x USB to UART Bridge (COMx)** thì driver đã có. Ghi lại số COM.
   - Nếu không thấy, cài driver **CP210x** (bản 11.x). Tải từ trang Silicon Labs hoặc Microsoft Update Catalog (tìm "CP210x"), rồi cắm lại cáp.

### 3.2. Arduino CLI, lõi ESP32 và thư viện
Cài [Arduino IDE 2](https://www.arduino.cc/en/software) (có sẵn `arduino-cli`) hoặc chỉ cài `arduino-cli`. Sau đó mở PowerShell:

```powershell
arduino-cli config init
arduino-cli config add board_manager.additional_urls https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli core update-index
arduino-cli core install esp32:esp32@3.3.12

arduino-cli lib install "MFRC522@1.4.12"
arduino-cli lib install "Adafruit Fingerprint Sensor Library@2.1.4"
arduino-cli lib install "NimBLE-Arduino@2.5.1"
```

Các phiên bản trên là bản đã chạy thử với dự án. Bản mới hơn có thể đổi API.

### 3.3. Biên dịch và nạp
Firmware lớn hơn 1,2 MB nên **phải** chọn bảng phân vùng `huge_app`. Thay `COM3` bằng số COM của bạn:

```powershell
cd KhoaBaoMat
arduino-cli compile --fqbn esp32:esp32:esp32:PartitionScheme=huge_app --upload -p COM3 firmware/smart_lock
```

Nếu dùng Arduino IDE thì chọn: **Board** "ESP32 Dev Module", **Partition Scheme** "Huge APP (3MB No OTA/1MB SPIFFS)", **Port** COMx. Sau đó mở `firmware/smart_lock/smart_lock.ino` và bấm Upload.

### 3.4. Kiểm tra
Mở Serial Monitor ở tốc độ **115200** rồi bấm nút **EN** trên mạch:

```powershell
arduino-cli monitor -p COM3 -c baudrate=115200
```

Khởi động đúng sẽ in ra các dòng tương tự:

```
=== KHOA BAO MAT - FIRMWARE GIAI DOAN 3 ...
[KHOA] Da ghep doi 0 dien thoai
[NUT] Dung nut ngoai GPIO34 (da co dien tro keo len)
[BLE] Dang quang ba 'Khoabaomat', dia chi xx:xx:xx:xx:xx:xx
```

Nếu thấy dòng `GPIO34 chua co dien tro keo len -> dung tam NUT BOOT`, nghĩa là nút ngoài chưa có điện trở 10k. Firmware sẽ tạm dùng nút **BOOT** trên mạch ESP32.

Thư mục `firmware/` còn có các chương trình test riêng từng linh kiện: `rfid_test`, `keypad_test`, `fingerprint_test`, `button_diag`, `hardware_test`. Nạp chúng giống cách trên (đổi tên thư mục) khi cần dò lỗi phần cứng. Test xong nhớ nạp lại `smart_lock`.

---

## 4. Cài app trên điện thoại

### Cách 1: cài APK có sẵn (khuyên dùng)
1. Tải [release/Khoabaomat.apk](release/Khoabaomat.apk) (89 MB) về điện thoại.
   - Yêu cầu Android 7.0 trở lên và **chip 64-bit (arm64)**. Gần như mọi điện thoại từ năm 2017 trở đi đều đáp ứng.
   - Máy 32-bit đời cũ thì phải tự build bằng cách 2 và bỏ tham số `--target-platform`.
2. Mở file. Nếu Android hỏi, cho phép **"Cài ứng dụng không rõ nguồn gốc"** với trình duyệt hoặc trình quản lý file.
3. Lần đầu mở app, **cho phép** các quyền:
   - **Thiết bị ở gần / Bluetooth**: để tìm và kết nối khoá.
   - **Camera**: chỉ dùng khi mở bằng khuôn mặt.
   - Android 11 trở xuống sẽ hỏi thêm **Vị trí**. Đây là yêu cầu của Android khi quét Bluetooth, app không dùng vị trí của bạn.
4. Điện thoại cần đã cài **khoá màn hình** (vân tay, khuôn mặt hoặc mã PIN của máy). App dùng nó để xác nhận trước mỗi lần mở cửa.

Nếu Google Play Protect cảnh báo, chọn "Vẫn cài đặt". APK được ký bằng khoá debug của nhóm, không qua Play Store.

### Cách 2: tự build từ mã nguồn
Cần Flutter 3.47 (Dart 3.13) và Android SDK:

```powershell
flutter pub get
flutter build apk --release --target-platform android-arm64   # ~89 MB; bỏ --target-platform để chạy mọi loại máy (~125 MB)
# File ra: build\app\outputs\flutter-apk\app-release.apk
adb install -r build\app\outputs\flutter-apk\app-release.apk
```

---

## 5. Hướng dẫn sử dụng

### 5.1. Ghép đôi lần đầu (điện thoại đầu tiên thành **admin**)
1. Bật Bluetooth, đứng gần khoá, mở app và bấm **Tìm khoá**. Chọn **Khoabaomat** trong danh sách.
2. App báo *"Điện thoại này chưa ghép đôi với khoá"*.
3. **Giữ nút trong nhà 5 giây**. LED xanh nhấp nháy, khoá mở chế độ ghép đôi trong **60 giây**.
4. App hiện một **mã 6 số**. **Gõ mã đó trên bàn phím của khoá**. Gõ đủ 6 số là khoá tự xác nhận, bấm `*` để xoá nếu gõ nhầm. Sai 3 lần thì phải làm lại từ bước 3.
5. App báo **Ghép đôi thành công** rồi chuyển sang trang điều khiển.

> Điện thoại ghép đôi **đầu tiên** là **admin**, có toàn quyền quản lý. Các máy ghép sau là **thành viên**, chỉ mở và khoá được. Khoá nhớ tối đa 8 điện thoại.
> Ghép đôi bắt buộc phải đứng cạnh khoá, vì cần giữ nút trong nhà và gõ mã trên bàn phím. Người ở ngoài không thể tự ghép đôi.

### 5.2. Mở cửa
| Cách | Thao tác |
|---|---|
| **App** | Mở app, chọn khoá, bấm **Mở cửa**, rồi xác thực bằng vân tay/khuôn mặt/mã của máy. Nếu đã bật "Mở khoá bằng khuôn mặt" thì nút là **Mở cửa bằng khuôn mặt**: nhìn camera, nháy mắt, giữ yên. |
| **Thẻ RFID** | Đưa thẻ đã đăng ký lại gần đầu đọc |
| **Vân tay** | Đặt ngón tay đã đăng ký lên cảm biến |
| **Mã PIN / mã khách** | Gõ mã trên bàn phím rồi bấm `#`. Bấm `*` để xoá |
| **Nút trong nhà** | Bấm nhanh (dưới 1 giây) để mở. Bấm lần nữa để khoá. Nếu quên thì khoá tự đóng sau 30 giây |

Mở bằng app, thẻ, vân tay hay PIN thì cửa mở **5 giây** rồi tự khoá lại. Muốn khoá sớm, bấm **Khoá ngay** trong app.

**Tín hiệu trên khoá:**
- LED xanh sáng: cửa đang mở.
- LED xanh nhấp nháy: đang chờ ghép đôi.
- LED đỏ nháy: bị từ chối (thẻ hoặc vân tay lạ, sai PIN).
- Còi bíp ngắn khi mở cửa.

### 5.3. Trang điều khiển
- Hiện trạng thái khoá: đang mở hay khoá, thời gian đã chạy, số lần mở, số điện thoại đã ghép.
- **Làm mới**: đọc lại trạng thái. **Kết nối lại**: dùng khi mất kết nối.
- Menu ⋮ có mục **Bỏ ghép đôi trên máy này**: xoá khoá bí mật trên điện thoại này. Muốn dùng lại thì phải ghép đôi lại.
- Máy admin có thêm 2 mục **Quản lý truy cập** và **Nhật ký**. App sẽ hỏi xác thực trước khi mở các mục này.

### 5.4. Quản lý truy cập (admin)
| Mục | Cách dùng |
|---|---|
| **Mã PIN** | Bấm để đặt mã 4–8 số, hoặc **Tắt** để bỏ PIN |
| **Mã khách** | **Mã khách mới**: nhập mã và thời hạn (phút/giờ). Khoá tự bỏ mã khi hết hạn. **Xoá** để huỷ sớm |
| **Thẻ RFID** | **Thêm thẻ**, rồi trong 15 giây đưa thẻ mới vào đầu đọc. **Xoá thẻ** để bỏ từng thẻ |
| **Vân tay** | **Thêm vân tay**: đặt ngón tay, nhấc ra, rồi đặt lại lần 2 theo hướng dẫn trên app. **Xoá vân tay** để bỏ |
| **Điện thoại** | Danh sách máy đã ghép. **Thu hồi** để cấm một máy (admin không tự thu hồi chính mình). Thêm máy mới: giữ nút trong nhà 5 giây rồi ghép đôi trên máy mới như mục 5.1 |
| **Mở khoá bằng khuôn mặt** | **Đăng ký**: chụp 5 ảnh khuôn mặt. Sau đó nút Mở cửa sẽ quét khuôn mặt. Dữ liệu khuôn mặt chỉ lưu trên điện thoại này. **Xoá** để quay lại dùng vân tay hoặc mã của máy |
| **Wi-Fi của khoá** | **Cài**: nhập tên mạng và mật khẩu. **Chỉ dùng được Wi-Fi 2,4 GHz.** Có Wi-Fi thì khoá lấy được giờ chuẩn (nhật ký và mã khách đúng giờ), và app mở được qua mạng trong nhà |
| **Điều khiển từ xa** | Nhập máy chủ MQTT có TLS, ví dụ [HiveMQ Cloud](https://www.hivemq.com/products/mqtt-cloud-broker/) bản miễn phí: **Host** dạng `abc123.s1.eu.hivemq.cloud`, **Cổng** 8883, **tài khoản** và **mật khẩu**. Bấm **Lưu và gửi cho khoá**. Khoá phải có Wi-Fi trước. Thông tin máy chủ được lưu trên điện thoại vừa nhập |

Máy chủ trung gian chỉ chuyển gói tin đã mã hoá, nên **không đọc được và không tự mở cửa được**.

### 5.5. Nhật ký
Admin mở mục **Nhật ký** để xem 60 lần ra vào gần nhất. Mỗi dòng cho biết thời gian, cách mở (app, thẻ, vân tay, PIN, nút, từ xa) và kết quả (thành công, thẻ lạ, sai PIN, bàn phím bị khoá). Khoá lưu tối đa 500 bản ghi, bản cũ nhất bị ghi đè khi đầy.

### 5.6. Khôi phục cài đặt gốc
**Giữ nút trong nhà 15 giây**, còi kêu 3 tiếng. Khoá **xoá hết** điện thoại đã ghép, thẻ, vân tay và PIN. Nhật ký vẫn được giữ lại. Sau đó ghép đôi lại từ đầu như mục 5.1, và máy ghép đầu tiên sẽ là admin mới.

> Giữ 5 giây là vào chế độ ghép đôi, đến 15 giây là xoá hết. Khi chỉ muốn ghép đôi, **thả tay ngay** khi thấy LED xanh nhấp nháy.

---

## 6. Xử lý sự cố

| Hiện tượng | Cách xử lý |
|---|---|
| Máy tính không thấy cổng COM | Thay cáp USB có truyền dữ liệu, đổi cổng USB, cài driver CP210x |
| Device Manager báo *Unknown USB Device (Device Descriptor Request Failed)* | Rút adapter 12V hoặc dây 5V từ LM2596 vào đế, chỉ để ESP32 lấy điện từ USB. Đổi cáp, đổi cổng |
| Nạp code báo lỗi *Sketch too big* | Chưa chọn Partition Scheme `huge_app` |
| Biên dịch báo thiếu `NimBLEDevice.h` / `MFRC522.h` | Cài thư viện ở mục 3.2 |
| Nhấn nút trong nhà thì mạch tắt | Nút đang nối thẳng 3,3V xuống GND. Nối lại theo mục 2: 3,3V **qua điện trở 10k** vào nút |
| Nhấn nút, LED xanh sáng nhưng relay không kêu | Relay không có 5V ở DC+. Kiểm tra LM2596 đã cắm 12V và ra đúng 5,0V, hoặc dây IN có cắm đúng chân S hàng 22 |
| App không tìm thấy khoá | Bật Bluetooth, cấp quyền "Thiết bị ở gần" (Android 11 trở xuống: bật cả Vị trí), đứng trong khoảng 5 m. Thử bấm EN trên ESP32 |
| Ghép đôi báo *khoá chưa ở chế độ ghép đôi* | Giữ nút trong nhà đủ 5 giây (LED xanh nhấp nháy) **rồi** mới bấm ghép đôi trong app |
| App báo *không đủ quyền* | Chỉ máy admin mới quản lý được. Nếu mất máy admin, khôi phục cài đặt gốc (mục 5.6) |
| Gõ PIN không có tác dụng | Có thể bàn phím đang bị khoá 5 phút sau 5 lần sai. Chờ hết thời gian rồi thử lại |
| Khoá không vào được Wi-Fi | Chỉ hỗ trợ 2,4 GHz. Kiểm tra lại mật khẩu |
| Bàn phím ra sai ký tự (bấm 1 ra A) | Hai dây cột C1 và C4 bị lộn |
| Vân tay không phản hồi | Kiểm tra dây TX/RX của AS608 có cắm **chéo** chưa (TX vào 16, RX vào 17) |

---

## 7. Dành cho lập trình viên

```
firmware/smart_lock/   firmware chính
  config.h             chân GPIO, thời gian, mã lệnh
  crypto_util.h        AES-GCM, X25519, HKDF (mbedtls)
  storage.h            điện thoại đã ghép (NVS)
  access_store.h       thẻ / vân tay / PIN / mã khách
  access_log.h         nhật ký (LittleFS)
  wifi_link.h          Wi-Fi + giờ NTP
  lan_link.h           điều khiển qua mạng trong nhà (TCP/UDP 4545)
  mqtt_link.h          điều khiển từ xa qua MQTT TLS
firmware/*_test, button_diag, hardware_test   chương trình test phần cứng
lib/                   app Flutter (Clean Architecture + Bloc, get_it)
  core/                ble, crypto, link, storage, di, theme
  features/            device, unlock, biometric, face, access
test/                  unit test
integration_test/      test với khoá thật
assets/models/         model FaceNet-512 (TFLite)
```

**Chạy test:**
```powershell
flutter analyze
flutter test
flutter test integration_test/ble_lock_test.dart -d <thiết bị>   # cần khoá thật ở gần
```

**Bảo mật tóm tắt:**
- Ghép đôi dùng trao đổi khoá X25519, xác nhận bằng mã 6 số gõ trên khoá.
- Mỗi điện thoại có khoá AES-256 riêng.
- Mỗi lệnh dùng nonce do khoá cấp (sống 10 giây, chỉ dùng 1 lần) kèm bộ đếm tăng dần, nên gửi lại gói cũ sẽ bị từ chối.
- PIN chỉ lưu dạng băm SHA-256 có salt.
- Hạn chế đã biết:
  - UID thẻ RFID có thể bị sao chép.
  - Mật khẩu Wi-Fi và MQTT nằm dạng thường trong flash ESP32 (chưa bật mã hoá flash).

**Tài liệu thêm:**
- [SO_DO_NOI_DAY.md](SO_DO_NOI_DAY.md): nối dây.
- [KIEN_TRUC_APP.md](KIEN_TRUC_APP.md): kiến trúc và giao thức.
- [TIEN_DO.md](TIEN_DO.md): tiến độ và kết quả test.
