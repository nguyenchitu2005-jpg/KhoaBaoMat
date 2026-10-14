// Wi-Fi cua khoa: ten mang + mat khau do app gui qua BLE (lenh CMD_SET_WIFI), luu trong NVS,
// tu ket noi lai khi mat song, lay gio chuan qua NTP de nhat ky / ma khach dung gio ca khi vua mat dien.
// Mat khau nam o dang thuong trong flash (chua bat ma hoa flash cua ESP32).
#pragma once
#include <WiFi.h>
#include <Preferences.h>
#include <time.h>
#include "config.h"

enum WifiState : uint8_t { WIFI_NOT_SET = 0, WIFI_CONNECTING = 1, WIFI_CONNECTED = 2, WIFI_FAILED = 3 };

class WifiLink {
 public:
  void begin() {
    prefs_.begin("wifi", false);
    ssid_ = prefs_.getString("ssid", "");
    pass_ = prefs_.getString("pass", "");
    WiFi.persistent(false);  // ten / mat khau da luu o NVS "wifi", khong de thu vien ghi them ban sao
    WiFi.setAutoReconnect(true);
    if (ssid_.length()) connect();
    else WiFi.mode(WIFI_OFF);
  }

  // ssid rong = quen Wi-Fi va tat song
  void set(const String &ssid, const String &pass) {
    ssid_ = ssid;
    pass_ = pass;
    if (ssid_.isEmpty()) {
      prefs_.remove("ssid");
      prefs_.remove("pass");
      WiFi.disconnect(true);
      WiFi.mode(WIFI_OFF);
      state_ = WIFI_NOT_SET;
      Serial.println("[WIFI] Da quen Wi-Fi");
      return;
    }
    prefs_.putString("ssid", ssid_);
    prefs_.putString("pass", pass_);
    connect();
  }

  bool connected() const { return state_ == WIFI_CONNECTED; }
  bool ntpSynced() const { return ntpSynced_; }

  // Goi trong loop(): theo doi trang thai, bat NTP khi vua co mang.
  // Tra ve gio unix lay tu NTP (moi NTP_RESYNC_MS 1 lan) de dong bo nhat ky, 0 neu chua den luc / chua co.
  uint32_t poll(uint32_t now) {
    WifiState s = currentState(now);
    if (s != state_) {
      state_ = s;
      if (s == WIFI_CONNECTED) {
        Serial.printf("[WIFI] Da ket noi '%s', IP %s, song %d dBm\n", ssid_.c_str(), WiFi.localIP().toString().c_str(), WiFi.RSSI());
        if (!ntpStarted_) { configTime(0, 0, NTP_SERVER_1, NTP_SERVER_2); ntpStarted_ = true; }  // gio UTC
      } else if (s == WIFI_FAILED) {
        Serial.printf("[WIFI] Khong ket noi duoc '%s' (sai mat khau / khong thay mang 2,4 GHz)\n", ssid_.c_str());
      } else if (s == WIFI_CONNECTING) {
        Serial.printf("[WIFI] Dang ket noi '%s'...\n", ssid_.c_str());
      }
    }
    if (s != WIFI_CONNECTED || (lastNtp_ && now - lastNtp_ < NTP_RESYNC_MS)) return 0;
    if (now - lastNtpTry_ < 1000) return 0;  // SNTP chay nen, chi can hoi lai gio moi giay
    lastNtpTry_ = now;
    time_t t = time(nullptr);
    if (t < 1700000000) return 0;  // chua lay duoc gio
    if (!ntpSynced_) Serial.println("[WIFI] Da lay gio chuan qua NTP");
    ntpSynced_ = true;
    lastNtp_ = now;
    return (uint32_t)t;
  }

  // [trang thai][song dBm (so co dau)][IP 4B][gio NTP da dong bo][do dai ten][ten]
  size_t status(uint8_t *out) const {
    IPAddress ip = connected() ? WiFi.localIP() : IPAddress(0, 0, 0, 0);
    out[0] = state_;
    out[1] = (uint8_t)(int8_t)(connected() ? WiFi.RSSI() : 0);
    for (int i = 0; i < 4; i++) out[2 + i] = ip[i];
    out[6] = ntpSynced_;
    size_t n = min((size_t)ssid_.length(), (size_t)WIFI_SSID_MAX);
    out[7] = n;
    memcpy(out + 8, ssid_.c_str(), n);
    return 8 + n;
  }

 private:
  void connect() {
    WiFi.mode(WIFI_STA);
    WiFi.disconnect();
    WiFi.begin(ssid_.c_str(), pass_.c_str());
    connectSince_ = millis();
    state_ = WIFI_NOT_SET;  // poll() se bao "dang ket noi"
  }

  WifiState currentState(uint32_t now) const {
    if (ssid_.isEmpty()) return WIFI_NOT_SET;
    wl_status_t w = WiFi.status();
    if (w == WL_CONNECTED) return WIFI_CONNECTED;
    if (w == WL_NO_SSID_AVAIL || w == WL_CONNECT_FAILED) return WIFI_FAILED;
    // Sai mat khau thuong chi hien la "mat ket noi" lap lai: qua WIFI_CONNECT_MS thi bao loi
    if (state_ != WIFI_CONNECTED && now - connectSince_ >= WIFI_CONNECT_MS) return WIFI_FAILED;
    return WIFI_CONNECTING;
  }

  Preferences prefs_;
  String ssid_, pass_;
  WifiState state_ = WIFI_NOT_SET;
  uint32_t connectSince_ = 0, lastNtp_ = 0, lastNtpTry_ = 0;
  bool ntpStarted_ = false, ntpSynced_ = false;
};
