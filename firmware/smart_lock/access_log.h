// Nhat ky ra vao: vong tron LOG_CAPACITY ban ghi x 16 byte trong LittleFS (/log.bin).
// Ban ghi: [thoi gian 4B][co 1B: bit0 = gio that (unix), 0 = giay tu luc khoi dong]
//          [phuong thuc 1B][ai 1B][ket qua 1B][du lieu them 8B (vd. UID the la)]
// Gio that lay tu lenh cua app (moi lenh ma hoa deu kem unixTime) -> khong can pin RTC.
#pragma once
#include <LittleFS.h>
#include "config.h"

struct LogRecord {
  uint32_t time;
  uint8_t flags;
  uint8_t method;
  uint8_t who;
  uint8_t result;
  uint8_t extra[8];
};
static_assert(sizeof(LogRecord) == 16, "LogRecord phai 16 byte");

class AccessLog {
 public:
  bool begin() {
    ok_ = LittleFS.begin(true);  // tu format lan dau
    if (!ok_) return false;
    File f = LittleFS.open(PATH, "r");
    if (f && f.size() >= 4) f.read((uint8_t *)&total_, 4);
    if (f) f.close();
    return true;
  }

  // ---------- Dong ho ----------
  void syncTime(uint32_t unixTime) {
    if (unixTime < 1700000000UL) return;  // bo qua gio vo ly
    baseUnix_ = unixTime;
    baseMillis_ = millis();
  }
  bool timeSynced() const { return baseUnix_ != 0; }
  uint32_t nowUnix() const { return baseUnix_ ? baseUnix_ + (millis() - baseMillis_) / 1000 : 0; }

  // ---------- Ghi / doc ----------
  void add(uint8_t method, uint8_t who, uint8_t result, const uint8_t *extra = nullptr, size_t extraLen = 0) {
    if (!ok_) return;
    LogRecord r = {};
    if (timeSynced()) { r.time = nowUnix(); r.flags = 1; }
    else r.time = millis() / 1000;
    r.method = method;
    r.who = who;
    r.result = result;
    if (extra) memcpy(r.extra, extra, extraLen > 8 ? 8 : extraLen);

    File f = LittleFS.open(PATH, LittleFS.exists(PATH) ? "r+" : "w+");
    if (!f) return;
    f.seek(4 + (total_ % LOG_CAPACITY) * sizeof(LogRecord));
    f.write((const uint8_t *)&r, sizeof(r));
    total_++;
    f.seek(0);
    f.write((const uint8_t *)&total_, 4);
    f.close();
  }

  uint32_t total() const { return total_; }

  // Doc toi da maxCount ban ghi bat dau tu so thu tu tuyet doi 'from' (ban ghi qua cu da bi ghi de -> nhay toi ban cu nhat con lai)
  int read(uint32_t from, LogRecord *out, int maxCount) const {
    if (!ok_) return 0;
    uint32_t oldest = total_ > LOG_CAPACITY ? total_ - LOG_CAPACITY : 0;
    if (from < oldest) from = oldest;
    int n = 0;
    File f = LittleFS.open(PATH, "r");
    if (!f) return 0;
    for (uint32_t i = from; i < total_ && n < maxCount; i++, n++) {
      f.seek(4 + (i % LOG_CAPACITY) * sizeof(LogRecord));
      f.read((uint8_t *)&out[n], sizeof(LogRecord));
    }
    f.close();
    return n;
  }

  void clear() {
    LittleFS.remove(PATH);
    total_ = 0;
  }

 private:
  static constexpr const char *PATH = "/log.bin";
  bool ok_ = false;
  uint32_t total_ = 0;
  uint32_t baseUnix_ = 0;
  uint32_t baseMillis_ = 0;
};
