# Sơ đồ nối dây – Khóa bảo mật ESP32

Danh sách từng sợi dây, đánh số để đấu xong sợi nào thì tích sợi đó (sửa `[ ]` thành `[x]`).

**Quy ước**

- Màu dây ghi theo đúng màu trong hình.
- **Cụm X** là cụm 3 chân **S-V-G** có nhãn X trên đế:
  - **S**: tín hiệu
  - **V**: 3,3V
  - **G**: GND

## Trước khi đấu

- [ ] Đặt jumper **JUMP** về **3V3**

---

## 1. Nguồn 12V và chốt khóa (dây đỏ đậm / xám)

| ✔ | # | Từ | Đến |
|:-:|:-:|---|---|
| [ ] | 1 | Adapter 12V | Cắm vào jack DC cái |
| [ ] | 2 | Jack cái + | Jack DC đực + |
| [ ] | 3 | Jack cái − | Jack DC đực − |
| [ ] | 4 | Jack DC đực | Cắm vào jack DC6.5-16V của đế |
| [ ] | 5 | Jack cái + | Relay COM |
| [ ] | 6 | Relay NO | Chốt khóa + |
| [ ] | 7 | Jack cái − | Chốt khóa − |
| [ ] | 8 | Diode 1N4007 | Song song 2 cực khóa, **vạch trắng về +** |

## 2. Relay (cam / xám / vàng)

| ✔ | # | Từ | Đến |
|:-:|:-:|---|---|
| [ ] | 9 | Cụm nguồn góc dưới trái: chân 5V | Relay DC+ |
| [ ] | 10 | G cụm 22 | Relay DC− |
| [ ] | 11 | S cụm 22 | Relay IN |

## 3. Breadboard (tím hồng / xám)

| ✔ | # | Từ | Đến |
|:-:|:-:|---|---|
| [ ] | 12 | Cụm nguồn: chân 3.3V | Đường + (đỏ) của breadboard |
| [ ] | 13 | Cụm nguồn: chân GND | Đường − (xanh) của breadboard |

## 4. RFID RC522 (xanh dương), toàn bộ ở hàng chân phải

| ✔ | # | Chân RC522 | Đến |
|:-:|:-:|---|---|
| [ ] | 14 | SDA | S cụm 5 |
| [ ] | 15 | SCK | S cụm 18 |
| [ ] | 16 | MOSI | S cụm 23 |
| [ ] | 17 | MISO | S cụm 19 |
| [ ] | 18 | RST | S cụm 4 |
| [ ] | 19 | GND | G cụm 4 |
| [ ] | 20 | 3.3V | V cụm 4 |
| – | – | IRQ | *Bỏ trống* |

## 5. Vân tay AS608 (xanh lá), hàng chân phải

| ✔ | # | Chân AS608 | Đến |
|:-:|:-:|---|---|
| [ ] | 21 | V+ | V cụm RX2 |
| [ ] | 22 | TX | S cụm RX2 (**đấu chéo**) |
| [ ] | 23 | RX | S cụm TX2 (**đấu chéo**) |
| [ ] | 24 | GND | G cụm TX2 |
| – | – | TCH, VA | *Bỏ trống* |

## 6. Bàn phím 4×4 (tím)

| ✔ | # | Chân phím | Đến |
|:-:|:-:|---|---|
| [ ] | 25 | R1 | S cụm D13 (trái) |
| [ ] | 26 | R2 | S cụm D14 (trái) |
| [ ] | 27 | R3 | S cụm D27 (trái) |
| [ ] | 28 | R4 | S cụm D26 (trái) |
| [ ] | 29 | C1 | S cụm D25 (trái) |
| [ ] | 30 | C2 | S cụm D33 (trái) |
| [ ] | 31 | C3 | S cụm D32 (trái) |
| [ ] | 32 | C4 | S cụm 21 (hàng phải) |

## 7. LED (xanh ngọc / xám)

| ✔ | # | Từ | Đến |
|:-:|:-:|---|---|
| [ ] | 33 | S cụm 2 | Điện trở 220Ω → chân dài LED **xanh** |
| [ ] | 34 | S cụm 15 | Điện trở 220Ω → chân dài LED **đỏ** |
| [ ] | 35 | Chân ngắn của cả 2 LED | Chân GND ở cụm D22 / D21 / VCC / GND (góc dưới phải) |

## 8. Nút mở và buzzer trên breadboard (xanh ngọc / xám)

| ✔ | # | Từ | Đến |
|:-:|:-:|---|---|
| [ ] | 36 | S cụm D34 (trái) | Nút nhấn chân 1 |
| [ ] | 37 | Điện trở 10k | Từ nút chân 1 lên đường + |
| [ ] | 38 | Nút nhấn chân 2 | Đường − |
| [ ] | 39 | S cụm D12 (trái) | Buzzer + |
| [ ] | 40 | Buzzer − | Đường − |

---

## Bảng tổng hợp chân GPIO (dùng khi viết firmware)

| Thiết bị | Chức năng | GPIO |
|---|---|---|
| RC522 (SPI) | SS / SDA | 5 |
| | SCK | 18 |
| | MOSI | 23 |
| | MISO | 19 |
| | RST | 4 |
| AS608 (UART2) | ESP32 RX2 ← TX cảm biến | 16 |
| | ESP32 TX2 → RX cảm biến | 17 |
| Bàn phím 4×4 | Hàng R1, R2, R3, R4 | 13, 14, 27, 26 |
| | Cột C1, C2, C3, C4 | 25, 33, 32, 21 |
| Relay | IN | 22 |
| LED xanh | Mở khóa thành công | 2 |
| LED đỏ | Từ chối / báo lỗi | 15 |
| Nút mở | Kéo lên ngoài 10k, **nhấn = LOW** | 34 |
| Buzzer | Còi báo | 12 |

## Lưu ý trước khi cấp điện

- **Mạch 12V (mục 1):** kiểm tra lại cực tính diode 1N4007 (vạch trắng về +) trước khi cắm adapter. Đấu ngược diode sẽ làm chập nguồn 12V khi relay đóng.
- **GPIO12 (buzzer):** là chân strapping. Không gắn điện trở kéo lên ở chân này, nếu không ESP32 có thể không khởi động.
- **GPIO2, GPIO15 (LED):** cũng là chân strapping. Đấu LED xuống GND như sơ đồ thì không sao.
- **GPIO34 (nút):** chỉ nhận tín hiệu vào và không có điện trở kéo lên bên trong, nên **bắt buộc** có điện trở 10k (dây 37).
- **Relay:** cấp 5V nhưng chân IN nhận 3,3V từ ESP32. Một số module kích mức thấp sẽ không nhả hẳn. Nếu relay không tắt, cần kiểm tra lại.
- **Nạp code:** nên ngắt adapter 12V trước khi nạp code qua USB (COM3).

## Thứ tự cấp điện thử

- [ ] 1. Chỉ cắm USB, kiểm tra ESP32 vẫn hiện ở **COM3**
- [ ] 2. Sau đó mới cắm adapter 12V
