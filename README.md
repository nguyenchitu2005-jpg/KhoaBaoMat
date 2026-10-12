# KhoaBaoMat

Khoá cửa thông minh: ESP32 (BLE, RFID RC522, vân tay AS608, bàn phím 4×4, relay) và app Flutter mở khoá bằng sinh trắc học.

- [TIEN_DO.md](TIEN_DO.md): tiến độ hiện tại
- [KIEN_TRUC_APP.md](KIEN_TRUC_APP.md): kiến trúc app và giao thức BLE
- [SO_DO_NOI_DAY.md](SO_DO_NOI_DAY.md): sơ đồ nối dây
- `firmware/smart_lock/`: firmware chính (arduino-cli, `esp32:esp32:esp32:PartitionScheme=huge_app`)
- `lib/`: app Flutter (Clean Architecture + Bloc)
