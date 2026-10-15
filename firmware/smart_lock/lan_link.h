// Dieu khien qua Wi-Fi trong nha (LAN): duong truyen thu hai cho DUNG cac goi nhu qua BLE
// (xin nonce, lenh da ma hoa AES-GCM, phan hoi da ma hoa), nen an toan nhu BLE.
// Ghep doi dien thoai moi van chi qua BLE (phai dung canh khoa go ma tren ban phim).
//  - TCP cong LAN_PORT, 1 dien thoai 1 luc; moi goi = [do dai 2B big-endian][goi].
//  - Tim khoa: app gui UDP "KBM?" + dia chi BLE 6B toi cong LAN_PORT (broadcast),
//    khoa co dung dia chi tra lai "KBM!" + dia chi BLE -> app biet IP cua khoa.
#pragma once
#include <WiFi.h>
#include <WiFiUdp.h>
#include "config.h"

class LanLink {
 public:
  void setId(const uint8_t bleMac[6]) { memcpy(mac_, bleMac, 6); }
  bool connected() { return had_ && client_.connected(); }

  // Goi trong loop(). Tra ve do dai goi vua nhan du (0 = chua co), goi chep vao buf.
  // dropped = true khi dien thoai vua ngat (de huy nonce / viec dang cho cua duong LAN).
  size_t poll(uint32_t now, bool wifiUp, uint8_t *buf, size_t cap, bool &dropped) {
    dropped = false;
    if (!wifiUp) return had_ ? drop(dropped, "mat Wi-Fi") : 0;
    if (!started_) {
      server_.begin();
      server_.setNoDelay(true);
      udp_.begin(LAN_PORT);
      started_ = true;
      Serial.printf("[LAN] Nghe cong %u (TCP lenh, UDP tim khoa)\n", LAN_PORT);
    }
    answerDiscovery();

    WiFiClient c = server_.accept();
    if (c) {
      if (had_) { client_.stop(); dropped = true; }  // ket noi moi thay ket noi cu (app ket noi lai)
      client_ = c;
      client_.setNoDelay(true);
      had_ = true;
      got_ = 0;
      lastRx_ = now;
      Serial.printf("[LAN] Dien thoai %s ket noi\n", client_.remoteIP().toString().c_str());
    }
    if (!had_) return 0;
    if (!client_.connected()) return drop(dropped, "dien thoai ngat");
    if (now - lastRx_ >= LAN_IDLE_MS) return drop(dropped, "qua lau khong gui gi");

    while (client_.available()) {
      int b = client_.read();
      if (b < 0) break;
      lastRx_ = now;
      if (got_ < 2) {
        head_[got_++] = (uint8_t)b;
        if (got_ == 2) {
          need_ = ((size_t)head_[0] << 8) | head_[1];
          if (need_ == 0 || need_ > sizeof(frame_) || need_ > cap) return drop(dropped, "goi sai do dai");
        }
        continue;
      }
      frame_[got_ - 2] = (uint8_t)b;
      if (++got_ == need_ + 2) {
        got_ = 0;
        memcpy(buf, frame_, need_);
        return need_;
      }
    }
    return 0;
  }

  void send(const uint8_t *d, size_t n) {
    if (!connected() || n > MAX_OUT) return;
    uint8_t out[2 + MAX_OUT];
    out[0] = n >> 8;
    out[1] = n & 0xFF;
    memcpy(out + 2, d, n);
    client_.write(out, 2 + n);  // 1 lan ghi: khong tach dau goi va than goi ra 2 goi TCP
  }

 private:
  static const size_t MAX_OUT = 2 + 12 + 6 + MAX_REPLY_PAYLOAD + 16;  // goi phan hoi lon nhat (sendSealedReply)

  size_t drop(bool &dropped, const char *why) {
    client_.stop();
    had_ = false;
    got_ = 0;
    dropped = true;
    Serial.printf("[LAN] Dong ket noi: %s\n", why);
    return 0;
  }

  void answerDiscovery() {
    int n = udp_.parsePacket();
    if (n <= 0) return;
    uint8_t q[10];
    int r = udp_.read(q, sizeof(q));
    if (n != 10 || r != 10 || memcmp(q, "KBM?", 4) != 0 || memcmp(q + 4, mac_, 6) != 0) return;
    uint8_t a[10] = {'K', 'B', 'M', '!'};
    memcpy(a + 4, mac_, 6);
    udp_.beginPacket(udp_.remoteIP(), udp_.remotePort());
    udp_.write(a, sizeof(a));
    udp_.endPacket();
  }

  WiFiServer server_{LAN_PORT};
  WiFiClient client_;
  WiFiUDP udp_;
  uint8_t mac_[6] = {0};
  uint8_t head_[2];
  uint8_t frame_[LAN_MAX_FRAME];
  size_t got_ = 0, need_ = 0;
  uint32_t lastRx_ = 0;
  bool started_ = false, had_ = false;
};
