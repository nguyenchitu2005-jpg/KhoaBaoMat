// Luu quyen truy cap tai khoa (NVS): the RFID, danh sach ID van tay trong AS608, ma PIN (chi luu ban bam).
#pragma once
#include <Preferences.h>
#include "mbedtls/sha256.h"
#include "esp_random.h"
#include "config.h"

struct Card {
  uint8_t active;
  uint8_t uidLen;
  uint8_t uid[10];
};

class AccessStore {
 public:
  void begin() {
    prefs_.begin("access", false);
    memset(cards_, 0, sizeof(cards_));
    if (prefs_.getBytesLength("cards") == sizeof(cards_)) prefs_.getBytes("cards", cards_, sizeof(cards_));
    fingerMask_ = prefs_.getULong("fingers", 0);
    pinSet_ = prefs_.getBytesLength("pinhash") == 32 && prefs_.getBytesLength("pinsalt") == 16;
    if (pinSet_) {
      prefs_.getBytes("pinsalt", pinSalt_, 16);
      prefs_.getBytes("pinhash", pinHash_, 32);
    }
    guestExp_ = prefs_.getULong("gexp", 0);
    if (prefs_.getBytesLength("ghash") != 32 || prefs_.getBytesLength("gsalt") != 16) guestExp_ = 0;
    if (guestExp_) {
      prefs_.getBytes("gsalt", guestSalt_, 16);
      prefs_.getBytes("ghash", guestHash_, 32);
    }
  }

  // ---------- The RFID ----------
  int findCard(const uint8_t *uid, uint8_t len) const {
    for (int i = 0; i < MAX_CARDS; i++)
      if (cards_[i].active && cards_[i].uidLen == len && memcmp(cards_[i].uid, uid, len) == 0) return i;
    return -1;
  }
  int addCard(const uint8_t *uid, uint8_t len) {
    if (len == 0 || len > sizeof(Card::uid)) return -1;
    for (int i = 0; i < MAX_CARDS; i++) {
      if (!cards_[i].active) {
        cards_[i].active = 1;
        cards_[i].uidLen = len;
        memcpy(cards_[i].uid, uid, len);
        saveCards();
        return i;
      }
    }
    return -1;
  }
  bool deleteCard(uint8_t index) {
    if (index == 0xFF) { memset(cards_, 0, sizeof(cards_)); saveCards(); return true; }
    if (index >= MAX_CARDS || !cards_[index].active) return false;
    memset(&cards_[index], 0, sizeof(Card));
    saveCards();
    return true;
  }
  const Card &card(int i) const { return cards_[i]; }
  int cardCount() const {
    int n = 0;
    for (auto &c : cards_) n += c.active;
    return n;
  }

  // ---------- Van tay (ID 1..MAX_FINGERS trong AS608) ----------
  bool hasFinger(uint16_t id) const { return id >= 1 && id <= MAX_FINGERS && (fingerMask_ >> (id - 1)) & 1; }
  int freeFingerId() const {
    for (int id = 1; id <= MAX_FINGERS; id++)
      if (!hasFinger(id)) return id;
    return -1;
  }
  void setFinger(uint16_t id, bool on) {
    if (id < 1 || id > MAX_FINGERS) return;
    if (on) fingerMask_ |= 1UL << (id - 1);
    else fingerMask_ &= ~(1UL << (id - 1));
    prefs_.putULong("fingers", fingerMask_);
  }
  void clearFingers() { fingerMask_ = 0; prefs_.putULong("fingers", 0); }
  uint32_t fingerMask() const { return fingerMask_; }

  // ---------- Ma PIN: SHA-256(salt 16B || cac chu so) ----------
  bool pinSet() const { return pinSet_; }
  void setPin(const char *digits, uint8_t len) {
    if (len == 0) {
      prefs_.remove("pinhash");
      prefs_.remove("pinsalt");
      pinSet_ = false;
      return;
    }
    esp_fill_random(pinSalt_, 16);
    hashPin(pinSalt_, digits, len, pinHash_);
    prefs_.putBytes("pinsalt", pinSalt_, 16);
    prefs_.putBytes("pinhash", pinHash_, 32);
    pinSet_ = true;
  }
  bool checkPin(const char *digits, uint8_t len) const {
    return pinSet_ && matches(pinSalt_, pinHash_, digits, len);
  }

  // ---------- Ma khach: PIN thu hai co han (unix giay), cung cach bam ----------
  bool guestSet() const { return guestExp_ != 0; }
  uint32_t guestExpiry() const { return guestExp_; }
  void setGuestPin(const char *digits, uint8_t len, uint32_t expiry) {
    if (len == 0 || expiry == 0) {
      prefs_.remove("ghash");
      prefs_.remove("gsalt");
      prefs_.remove("gexp");
      guestExp_ = 0;
      return;
    }
    esp_fill_random(guestSalt_, 16);
    hashPin(guestSalt_, digits, len, guestHash_);
    prefs_.putBytes("gsalt", guestSalt_, 16);
    prefs_.putBytes("ghash", guestHash_, 32);
    prefs_.putULong("gexp", expiry);
    guestExp_ = expiry;
  }
  // nowUnix = 0 (khoa chua duoc dong bo gio, vd. vua mat dien) -> tu choi. Qua han -> tu xoa ma.
  bool checkGuestPin(const char *digits, uint8_t len, uint32_t nowUnix) {
    if (!guestExp_ || nowUnix == 0) return false;
    if (nowUnix >= guestExp_) { setGuestPin("", 0, 0); return false; }
    return matches(guestSalt_, guestHash_, digits, len);
  }

  void clearAll() {
    deleteCard(0xFF);
    clearFingers();
    setPin("", 0);
    setGuestPin("", 0, 0);
  }

 private:
  void saveCards() { prefs_.putBytes("cards", cards_, sizeof(cards_)); }
  static bool matches(const uint8_t salt[16], const uint8_t hash[32], const char *digits, uint8_t len) {
    uint8_t h[32];
    hashPin(salt, digits, len, h);
    uint8_t diff = 0;  // so sanh khong phu thuoc thoi gian
    for (int i = 0; i < 32; i++) diff |= h[i] ^ hash[i];
    return diff == 0;
  }
  static void hashPin(const uint8_t salt[16], const char *digits, uint8_t len, uint8_t out[32]) {
    mbedtls_sha256_context c;
    mbedtls_sha256_init(&c);
    mbedtls_sha256_starts(&c, 0);
    mbedtls_sha256_update(&c, salt, 16);
    mbedtls_sha256_update(&c, (const uint8_t *)digits, len);
    mbedtls_sha256_finish(&c, out);
    mbedtls_sha256_free(&c);
  }

  Preferences prefs_;
  Card cards_[MAX_CARDS];
  uint32_t fingerMask_ = 0;
  bool pinSet_ = false;
  uint8_t pinSalt_[16];
  uint8_t pinHash_[32];
  uint32_t guestExp_ = 0;
  uint8_t guestSalt_[16];
  uint8_t guestHash_[32];
};
