// Luu dien thoai da ghep doi trong NVS (Preferences): khoa AES rieng, bo dem chong phat lai, vai tro.
// Bo dem duoc ghi lai sau MOI lenh -> khoi dong lai van chan duoc goi cu.
#pragma once
#include <Preferences.h>
#include "config.h"

enum PhoneRole : uint8_t { ROLE_ADMIN = 1, ROLE_MEMBER = 2 };

struct Phone {
  uint8_t id;      // keyId = vi tri + 1 (1..MAX_PHONES)
  uint8_t active;  // 1 = dang duoc phep
  uint8_t role;
  uint8_t reserved;
  uint8_t key[32];
  uint32_t lastCounter;
};

class PhoneStore {
 public:
  void begin() {
    prefs_.begin("khoa", false);
    memset(phones_, 0, sizeof(phones_));
    if (prefs_.getBytesLength("phones") == sizeof(phones_)) prefs_.getBytes("phones", phones_, sizeof(phones_));
    for (int i = 0; i < MAX_PHONES; i++) phones_[i].id = i + 1;
  }

  Phone *find(uint8_t id) {
    if (id < 1 || id > MAX_PHONES) return nullptr;
    Phone &p = phones_[id - 1];
    return p.active ? &p : nullptr;
  }

  int count() const {
    int n = 0;
    for (auto &p : phones_) n += p.active;
    return n;
  }

  int freeSlot() const {
    for (int i = 0; i < MAX_PHONES; i++)
      if (!phones_[i].active) return i;
    return -1;
  }

  // Dien thoai dau tien la admin
  Phone &add(int slot, const uint8_t key[32]) {
    Phone &p = phones_[slot];
    p.role = count() == 0 ? ROLE_ADMIN : ROLE_MEMBER;
    p.active = 1;
    memcpy(p.key, key, 32);
    p.lastCounter = 0;
    save();
    return p;
  }

  void save() { prefs_.putBytes("phones", phones_, sizeof(phones_)); }

  void clear() {
    memset(phones_, 0, sizeof(phones_));
    for (int i = 0; i < MAX_PHONES; i++) phones_[i].id = i + 1;
    save();
  }

 private:
  Preferences prefs_;
  Phone phones_[MAX_PHONES];
};
