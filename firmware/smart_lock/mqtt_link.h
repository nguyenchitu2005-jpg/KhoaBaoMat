// Dieu khien tu xa qua may chu trung gian MQTT (vd. HiveMQ Cloud), TLS cong 8883.
// Duong truyen thu ba cho DUNG cac goi nhu BLE / LAN: may chu chi chuyen goi da ma hoa AES-GCM,
// khong doc duoc va khong tu mo cua duoc. Ghep doi van chi qua BLE.
//  - App -> khoa: khoabaomat/<dia chi BLE>/c ; khoa -> app: .../e (moi goi MQTT = 1 goi nhu BLE)
//  - .../s: "1" khi khoa vao may chu, "0" (di chuc - may chu tu gui khi khoa mat mang). Giu lai (retain).
// Dia chi / tai khoan may chu do app gui qua lenh CMD_SET_MQTT, luu NVS "mqtt" (mat khau dang thuong).
#pragma once
#include <Preferences.h>
#include <mqtt_client.h>
#include <esp_crt_bundle.h>
#include "config.h"

enum MqttState : uint8_t { MQTT_NOT_SET = 0, MQTT_CONNECTING = 1, MQTT_CONNECTED = 2, MQTT_ERROR = 3 };

class MqttLink {
 public:
  void begin(const uint8_t bleMac[6]) {
    char id[13];
    snprintf(id, sizeof(id), "%02x%02x%02x%02x%02x%02x", bleMac[0], bleMac[1], bleMac[2], bleMac[3], bleMac[4], bleMac[5]);
    snprintf(cmdTopic_, sizeof(cmdTopic_), MQTT_TOPIC_PREFIX "/%s/c", id);
    snprintf(evtTopic_, sizeof(evtTopic_), MQTT_TOPIC_PREFIX "/%s/e", id);
    snprintf(stTopic_, sizeof(stTopic_), MQTT_TOPIC_PREFIX "/%s/s", id);
    snprintf(clientId_, sizeof(clientId_), "kbm-lock-%s", id);
    prefs_.begin("mqtt", false);
    host_ = prefs_.getString("host", "");
    port_ = prefs_.getUShort("port", 8883);
    user_ = prefs_.getString("user", "");
    pass_ = prefs_.getString("pass", "");
  }

  // host rong = tat dieu khien tu xa
  void set(const String &host, uint16_t port, const String &user, const String &pass) {
    stop();
    host_ = host;
    port_ = port;
    user_ = user;
    pass_ = pass;
    if (host_.isEmpty()) {
      prefs_.remove("host");
      Serial.println("[MQTT] Da tat dieu khien tu xa");
      return;
    }
    prefs_.putString("host", host_);
    prefs_.putUShort("port", port_);
    prefs_.putString("user", user_);
    prefs_.putString("pass", pass_);
  }

  bool connected() const { return connected_; }

  // Goi trong loop(): bat ket noi khi co Wi-Fi. Tra ve do dai goi vua nhan (0 = chua co), goi chep vao buf.
  size_t poll(bool wifiUp, uint8_t *buf, size_t cap) {
    if (!client_ && wifiUp && host_.length()) start();
    if (!rxReady_) return 0;
    size_t n = rxLen_ <= cap ? rxLen_ : 0;
    if (n) memcpy(buf, (const void *)rx_, n);
    rxReady_ = false;
    return n;
  }

  void send(const uint8_t *d, size_t n) {
    if (connected_) esp_mqtt_client_publish(client_, evtTopic_, (const char *)d, n, 0, 0);
  }

  // [trang thai][do dai host][host]
  size_t status(uint8_t *out) const {
    out[0] = host_.isEmpty() ? MQTT_NOT_SET : connected_ ? MQTT_CONNECTED : lastError_ ? MQTT_ERROR : MQTT_CONNECTING;
    size_t n = min((size_t)host_.length(), (size_t)MQTT_FIELD_MAX);
    out[1] = n;
    memcpy(out + 2, host_.c_str(), n);
    return 2 + n;
  }

 private:
  void start() {
    uri_ = "mqtts://" + host_ + ":" + String(port_);
    esp_mqtt_client_config_t cfg = {};
    cfg.broker.address.uri = uri_.c_str();
    cfg.broker.verification.crt_bundle_attach = esp_crt_bundle_attach;  // xac minh chung chi may chu (TLS)
    cfg.credentials.client_id = clientId_;
    cfg.credentials.username = user_.c_str();
    cfg.credentials.authentication.password = pass_.c_str();
    cfg.session.keepalive = MQTT_KEEPALIVE_S;
    cfg.session.last_will.topic = stTopic_;
    cfg.session.last_will.msg = "0";
    cfg.session.last_will.msg_len = 1;
    cfg.session.last_will.qos = 1;
    cfg.session.last_will.retain = 1;
    client_ = esp_mqtt_client_init(&cfg);
    if (!client_) { lastError_ = true; return; }
    esp_mqtt_client_register_event(client_, MQTT_EVENT_ANY, &MqttLink::onEvent, this);
    esp_mqtt_client_start(client_);  // thu vien tu ket noi lai khi mat mang
    Serial.printf("[MQTT] Dang ket noi %s ...\n", uri_.c_str());
  }

  void stop() {
    if (!client_) return;
    esp_mqtt_client_destroy(client_);
    client_ = nullptr;
    connected_ = false;
    lastError_ = false;
  }

  // Chay trong task cua thu vien MQTT: chi chep goi ra, loop() xu ly (giong BLE onWrite)
  static void onEvent(void *arg, esp_event_base_t, int32_t id, void *data) {
    MqttLink *self = (MqttLink *)arg;
    esp_mqtt_event_handle_t e = (esp_mqtt_event_handle_t)data;
    switch ((esp_mqtt_event_id_t)id) {
      case MQTT_EVENT_CONNECTED:
        self->connected_ = true;
        self->lastError_ = false;
        esp_mqtt_client_subscribe(self->client_, self->cmdTopic_, 0);
        esp_mqtt_client_publish(self->client_, self->stTopic_, "1", 1, 1, 1);
        Serial.printf("[MQTT] Da ket noi may chu, nghe %s (RAM trong %u byte)\n", self->cmdTopic_, (unsigned)ESP.getFreeHeap());
        break;
      case MQTT_EVENT_DISCONNECTED:
        if (self->connected_) Serial.println("[MQTT] Mat ket noi may chu (tu thu lai)");
        self->connected_ = false;
        break;
      case MQTT_EVENT_ERROR: {
        self->lastError_ = true;
        esp_mqtt_error_codes_t *h = e->error_handle;
        if (h && h->error_type == MQTT_ERROR_TYPE_CONNECTION_REFUSED) {
          Serial.printf("[MQTT] May chu tu choi (ma %d): sai tai khoan / mat khau\n", (int)h->connect_return_code);
        } else if (h) {
          // esp_tls: loi ket noi/TLS; tls_stack: ma loi mbedTLS (vd 0x7F00 = het RAM, 0x2700 = sai chung chi)
          Serial.printf("[MQTT] Loi ket noi: esp_tls 0x%x, tls_stack -0x%x, socket errno %d, RAM trong %u (khoi lon nhat %u)\n",
                        (unsigned)h->esp_tls_last_esp_err, (unsigned)-h->esp_tls_stack_err, h->esp_transport_sock_errno,
                        (unsigned)ESP.getFreeHeap(), (unsigned)ESP.getMaxAllocHeap());
        }
        break;
      }
      case MQTT_EVENT_DATA:
        // Goi tron ven, dung chu de lenh, goi truoc da xu ly xong (app luon cho phan hoi moi gui tiep)
        if (!self->rxReady_ && e->data_len == e->total_data_len && e->data_len > 0 &&
            (size_t)e->data_len <= sizeof(self->rx_) && e->topic_len == (int)strlen(self->cmdTopic_) &&
            memcmp(e->topic, self->cmdTopic_, e->topic_len) == 0) {
          memcpy((void *)self->rx_, e->data, e->data_len);
          self->rxLen_ = e->data_len;
          self->rxReady_ = true;
        }
        break;
      default:
        break;
    }
  }

  Preferences prefs_;
  String host_, user_, pass_, uri_;
  uint16_t port_ = 8883;
  char cmdTopic_[40], evtTopic_[40], stTopic_[40], clientId_[24];
  esp_mqtt_client_handle_t client_ = nullptr;
  volatile bool connected_ = false, lastError_ = false, rxReady_ = false;
  volatile uint8_t rx_[LAN_MAX_FRAME];
  volatile size_t rxLen_ = 0;
};
