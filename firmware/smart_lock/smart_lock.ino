// Firmware khoa thong minh - GIAI DOAN 2: ghep doi an toan + BLE + relay + nut + ban phim
//
// Ghep doi dien thoai moi:
//   1. Giu NUT TRONG NHA 5 giay -> LED xanh nhay, khoa mo che do ghep doi 60 giay
//      (nut trong nha = GPIO34 neu co dien tro keo len 10k, neu khong thi la nut BOOT tren mach ESP32)
//   2. App gui khoa cong khai X25519 -> khoa tra khoa cong khai cua no -> 2 ben tinh cung khoa AES + ma 6 so
//   3. Go ma 6 so hien tren app vao ban phim cua khoa (tu xac nhan khi du 6 so, hoac bam #; bam * de xoa)
// Nut trong nha: bam nhanh = mo cua | giu 5 giay = ghep doi | giu 15 giay = XOA het dien thoai da ghep
// Dinh dang goi: KIEN_TRUC_APP.md muc 4. Serial: 115200 baud

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLE2902.h>
#include "config.h"
#include "crypto_util.h"
#include "storage.h"

PhoneStore store;
BLECharacteristic *evtChar;

// ---- Goi BLE nhan duoc: callback chi chep vao day, loop() xu ly ----
uint8_t rxBuf[160];
volatile size_t rxLen = 0;
volatile bool rxReady = false;
volatile bool clientConnected = false;
volatile bool clientDropped = false;

// ---- Challenge ----
uint8_t pendingNonce[8];
bool nonceValid = false;
uint32_t nonceAt = 0;

// ---- Relay ----
bool relayOn = false;
uint32_t relayOffAt = 0;
uint32_t unlockCount = 0;

// ---- Ghep doi ----
bool pairingMode = false;
uint32_t pairDeadline = 0;
struct {
  bool active;
  int slot;
  uint8_t key[32];
  uint32_t code;
  uint8_t tries;
  char typed[9];
  uint8_t typedLen;
} pend;

// ---- Nut + ban phim ----
int buttonPin = BUTTON_EXT;

// ======================== Phan hoi ra ngoai ========================
void sendFrame(const uint8_t *data, size_t len) {
  evtChar->setValue(data, len);
  evtChar->notify();
}

void beep(int ms, int freq = 2700) {
  tone(BUZZER, freq, ms);
  delay(ms + 30);
}

void setRelay(bool on) {
  digitalWrite(RELAY_PIN, on ? RELAY_ON : !RELAY_ON);
  relayOn = on;
  relayOffAt = on ? millis() + UNLOCK_MS : 0;
  digitalWrite(LED_GREEN, on ? HIGH : LOW);
}

void unlockNow(const char *who) {
  setRelay(true);
  unlockCount++;
  Serial.printf("[KHOA] MO - %s (lan %lu)\n", who, (unsigned long)unlockCount);
  beep(80);
}

void flashRed(int ms = 400) {
  digitalWrite(LED_RED, HIGH);
  beep(ms, 900);
  digitalWrite(LED_RED, LOW);
}

// ======================== Lenh da ma hoa ========================
// Phan hoi: [0x82][keyId][IV 12][AES(cmd, result, counter 4B, payload)][tag 16]
void sendSealedReply(Phone *p, uint8_t cmd, uint8_t result, uint32_t counter,
                     const uint8_t *payload = nullptr, size_t payloadLen = 0) {
  uint8_t plain[6 + 32];
  if (payloadLen > 32) payloadLen = 32;
  plain[0] = cmd;
  plain[1] = result;
  plain[2] = counter >> 24; plain[3] = counter >> 16; plain[4] = counter >> 8; plain[5] = counter;
  if (payloadLen) memcpy(plain + 6, payload, payloadLen);
  size_t plainLen = 6 + payloadLen;

  uint8_t out[2 + 12 + sizeof(plain) + 16];
  out[0] = FRAME_SEALED_REPLY;
  out[1] = p->id;
  if (!gcmSeal(p->key, p->id, plain, plainLen, out + 2, out + 14, out + 14 + plainLen)) return;
  sendFrame(out, 14 + plainLen + 16);
}

// Lenh: [0x02][keyId][IV 12][ban ma][tag 16]; ban ro = [cmd][counter 4B][nonce 8B][unixTime 4B][payload]
void handleSealed(const uint8_t *f, size_t n) {
  if (n < 2 + 12 + 17 + 16) return;
  Phone *p = store.find(f[1]);
  if (!p) { Serial.printf("[BLE] keyId %u chua ghep doi / da bi xoa - bo qua\n", f[1]); return; }

  size_t ctLen = n - 2 - 12 - 16;
  uint8_t plain[96];
  if (ctLen > sizeof(plain)) return;
  if (!gcmOpen(p->key, p->id, f + 2, f + 14, ctLen, f + n - 16, plain)) {
    Serial.println("[BLE] TU CHOI: sai tag GCM (goi bi sua hoac sai khoa)");
    return;
  }

  uint8_t cmd = plain[0];
  uint32_t counter = ((uint32_t)plain[1] << 24) | ((uint32_t)plain[2] << 16) | ((uint32_t)plain[3] << 8) | plain[4];
  bool nonceOk = nonceValid && millis() - nonceAt < NONCE_TTL_MS && memcmp(plain + 5, pendingNonce, 8) == 0;
  nonceValid = false;  // nonce chi dung 1 lan
  if (!nonceOk) {
    Serial.printf("[BLE] TU CHOI: nonce sai/het han (dien thoai #%u)\n", p->id);
    sendSealedReply(p, cmd, RES_BAD_NONCE, counter);
    return;
  }
  if (counter <= p->lastCounter) {
    Serial.printf("[BLE] TU CHOI: bo dem %lu <= %lu (nghi phat lai)\n", (unsigned long)counter, (unsigned long)p->lastCounter);
    sendSealedReply(p, cmd, RES_BAD_COUNTER, counter);
    return;
  }
  p->lastCounter = counter;
  store.save();  // luu bo dem: khoi dong lai van chan duoc goi cu

  switch (cmd) {
    case CMD_UNLOCK: {
      char who[32];
      snprintf(who, sizeof(who), "app, dien thoai #%u", p->id);
      sendSealedReply(p, cmd, RES_OK, counter);
      unlockNow(who);
      break;
    }
    case CMD_LOCK:
      setRelay(false);
      Serial.printf("[KHOA] DONG - app, dien thoai #%u\n", p->id);
      sendSealedReply(p, cmd, RES_OK, counter);
      break;
    case CMD_STATUS: {
      // payload: [relayOn][uptime giay 4B][so lan mo 4B][so dien thoai][dang ghep doi]
      uint32_t up = millis() / 1000;
      uint8_t st[11] = {(uint8_t)relayOn,
                        (uint8_t)(up >> 24), (uint8_t)(up >> 16), (uint8_t)(up >> 8), (uint8_t)up,
                        (uint8_t)(unlockCount >> 24), (uint8_t)(unlockCount >> 16), (uint8_t)(unlockCount >> 8), (uint8_t)unlockCount,
                        (uint8_t)store.count(), (uint8_t)pairingMode};
      sendSealedReply(p, cmd, RES_OK, counter, st, sizeof(st));
      break;
    }
    default:
      sendSealedReply(p, cmd, RES_UNKNOWN_CMD, counter);
  }
}

// ======================== Ghep doi ========================
void sendPairError(uint8_t code) {
  uint8_t out[2] = {FRAME_PAIR_ERROR, code};
  sendFrame(out, 2);
}

void enterPairingMode() {
  pairingMode = true;
  pairDeadline = millis() + PAIR_WINDOW_MS;
  pend.active = false;
  Serial.println("[GHEP DOI] Mo che do ghep doi 60 giay - bam 'Ghep doi' tren app");
  beep(400, 2000);
}

void endPairing(uint8_t result) {
  uint8_t keyId = pend.active ? pend.slot + 1 : 0;
  if (pend.active && clientConnected) {
    uint8_t out[3] = {FRAME_PAIR_RESULT, result, keyId};
    sendFrame(out, 3);
  }
  if (result == PAIR_OK && pend.active) {
    Phone &p = store.add(pend.slot, pend.key);
    Serial.printf("[GHEP DOI] THANH CONG - dien thoai #%u (%s), tong %d dien thoai\n",
                  p.id, p.role == ROLE_ADMIN ? "admin" : "thanh vien", store.count());
    beep(100); delay(80); beep(100);
  } else {
    const char *why = result == PAIR_BAD_CODE ? "go sai ma qua 3 lan" : result == PAIR_TIMEOUT ? "het gio" : "huy";
    Serial.printf("[GHEP DOI] THAT BAI - %s\n", why);
    flashRed(600);
  }
  memset(&pend, 0, sizeof(pend));
  pairingMode = false;
  digitalWrite(LED_GREEN, relayOn ? HIGH : LOW);
}

// [0x03][khoa cong khai dien thoai 32B] -> [0x83][khoa cong khai khoa 32B][keyId]
void handlePairRequest(const uint8_t *f, size_t n) {
  if (n != 33) return;
  if (!pairingMode) {
    Serial.println("[GHEP DOI] Tu choi: chua o che do ghep doi (giu nut trong nha 5 giay truoc)");
    sendPairError(PAIR_NOT_IN_MODE);
    return;
  }
  if (pend.active) { sendPairError(PAIR_BUSY); return; }
  int slot = store.freeSlot();
  if (slot < 0) { sendPairError(PAIR_FULL); return; }

  uint8_t priv[32], pub[32], shared[32];
  bool ok = x25519Keypair(priv, pub) && x25519Shared(priv, f + 1, shared) &&
            derivePairing(shared, slot + 1, pend.key, &pend.code);
  memset(priv, 0, sizeof(priv));
  memset(shared, 0, sizeof(shared));
  if (!ok) { Serial.println("[GHEP DOI] Loi tinh toan X25519/HKDF"); sendPairError(0x13); return; }

  pend.active = true;
  pend.slot = slot;
  pend.tries = 0;
  pend.typedLen = 0;
  pairDeadline = millis() + PAIR_WINDOW_MS;  // 60 giay de go ma

  uint8_t out[34];
  out[0] = FRAME_PAIR_RESP;
  memcpy(out + 1, pub, 32);
  out[33] = slot + 1;
  sendFrame(out, sizeof(out));
  Serial.println("[GHEP DOI] Da trao khoa - GO MA 6 SO hien tren app vao ban phim (du 6 so la tu xac nhan)");
}

void onKeyPressed(char k) {
  if (!pend.active) return;  // giai doan 2: ban phim chi dung de xac nhan ghep doi
  tone(BUZZER, 3500, 40);
  if (k >= '0' && k <= '9') {
    if (pend.typedLen < 8) pend.typed[pend.typedLen++] = k;
  } else if (k == '*') {
    pend.typedLen = 0;
  }
  // Xac nhan khi bam # HOAC khi da go du 6 so
  if (k == '#' || (k >= '0' && k <= '9' && pend.typedLen == 6)) {
    pend.typed[pend.typedLen] = 0;
    char expect[8];
    snprintf(expect, sizeof(expect), "%06lu", (unsigned long)pend.code);
    if (pend.typedLen == 6 && strcmp(pend.typed, expect) == 0) {
      endPairing(PAIR_OK);
    } else {
      pend.tries++;
      pend.typedLen = 0;
      if (pend.tries >= PAIR_MAX_TRIES) {
        endPairing(PAIR_BAD_CODE);
      } else {
        Serial.printf("[GHEP DOI] Sai ma, con %u lan thu\n", PAIR_MAX_TRIES - pend.tries);
        flashRed(300);
      }
    }
  }
}

// ======================== BLE ========================
class CmdCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) override {
    if (rxReady) return;  // goi truoc chua xu ly xong -> bo (app luon cho phan hoi moi gui tiep)
    String v = c->getValue();
    size_t n = v.length();
    if (n == 0 || n > sizeof(rxBuf)) return;
    memcpy(rxBuf, v.c_str(), n);
    rxLen = n;
    rxReady = true;
  }
};

// Thong ke ket noi de log gon (toi da 1 dong/giay), kem dia chi may va ly do ngat
volatile uint32_t connectCount = 0, dropCount = 0;
volatile uint8_t lastDropReason = 0;
uint8_t lastPeer[6] = {0};

class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *s, esp_ble_gatts_cb_param_t *param) override {
    clientConnected = true;
    connectCount++;
    memcpy(lastPeer, param->connect.remote_bda, 6);
  }
  void onDisconnect(BLEServer *s, esp_ble_gatts_cb_param_t *param) override {
    clientConnected = false;
    clientDropped = true;
    dropCount++;
    lastDropReason = param->disconnect.reason;
    memcpy(lastPeer, param->disconnect.remote_bda, 6);
  }
};

void handleFrame(const uint8_t *f, size_t n) {
  switch (f[0]) {
    case FRAME_CHALLENGE_REQ:
      if (n != 2) return;
      esp_fill_random(pendingNonce, sizeof(pendingNonce));
      nonceValid = true;
      nonceAt = millis();
      {
        uint8_t out[9] = {FRAME_CHALLENGE};
        memcpy(out + 1, pendingNonce, 8);
        sendFrame(out, sizeof(out));
      }
      break;
    case FRAME_SEALED_CMD: handleSealed(f, n); break;
    case FRAME_PAIR_REQ: handlePairRequest(f, n); break;
    default: Serial.printf("[BLE] Goi la 0x%02X (%u byte), bo qua\n", f[0], (unsigned)n);
  }
}

// ======================== Nut + ban phim ========================
// Nut trong nha: dung GPIO34 neu chan nay dung yen o muc HIGH (co dien tro keo len), neu khong dung nut BOOT
void chooseButton() {
  pinMode(BUTTON_EXT, INPUT);
  int highs = 0;
  for (int i = 0; i < 200; i++) { highs += digitalRead(BUTTON_EXT) == HIGH; delay(1); }
  if (highs == 200) {
    buttonPin = BUTTON_EXT;
    Serial.println("[NUT] Dung nut ngoai GPIO34 (da co dien tro keo len)");
  } else {
    buttonPin = BUTTON_BOOT;
    pinMode(BUTTON_BOOT, INPUT_PULLUP);
    Serial.println("[NUT] GPIO34 chua co dien tro keo len -> dung tam NUT BOOT tren mach ESP32");
  }
}

void pollButton(uint32_t now) {
  static bool down = false, raw = false;
  static uint32_t rawSince = 0, downSince = 0;
  static uint8_t stage = 0;  // 0 = moi bam, 1 = da vao ghep doi, 2 = da xoa
  bool r = digitalRead(buttonPin) == LOW;
  if (r != raw) { raw = r; rawSince = now; }
  if (now - rawSince < 30) return;  // chong doi 30ms

  if (raw && !down) { down = true; downSince = now; stage = 0; }
  if (down && raw) {
    uint32_t held = now - downSince;
    if (stage == 0 && held >= HOLD_PAIR_MS) { stage = 1; enterPairingMode(); }
    if (stage == 1 && held >= HOLD_RESET_MS) {
      stage = 2;
      if (pend.active) endPairing(0xFF);
      pairingMode = false;
      store.clear();
      Serial.println("[NUT] DA XOA TAT CA dien thoai da ghep doi");
      for (int i = 0; i < 3; i++) { beep(300, 1500); delay(100); }
    }
  }
  if (down && !raw) {
    down = false;
    if (stage == 0 && now - downSince < 1000) unlockNow("nut trong nha");
  }
}

char scanKeypad() {
  for (int r = 0; r < 4; r++) {
    for (int i = 0; i < 4; i++) pinMode(KP_ROWS[i], INPUT);
    pinMode(KP_ROWS[r], OUTPUT);
    digitalWrite(KP_ROWS[r], LOW);
    delayMicroseconds(10);
    for (int c = 0; c < 4; c++)
      if (digitalRead(KP_COLS[c]) == LOW) { pinMode(KP_ROWS[r], INPUT); return KP_KEYS[r][c]; }
  }
  for (int i = 0; i < 4; i++) pinMode(KP_ROWS[i], INPUT);
  return 0;
}

void pollKeypad(uint32_t now) {
  static char raw = 0, stable = 0;
  static uint32_t since = 0;
  char k = scanKeypad();
  if (k != raw) { raw = k; since = now; }
  if (now - since >= 30 && raw != stable) {
    stable = raw;
    if (stable) onKeyPressed(stable);
  }
}

// ======================== setup / loop ========================
void setup() {
  pinMode(RELAY_PIN, OUTPUT);
  setRelay(false);  // relay TAT ngay khi khoi dong
  pinMode(LED_GREEN, OUTPUT);
  pinMode(LED_RED, OUTPUT);
  pinMode(BUZZER, OUTPUT);
  for (int c = 0; c < 4; c++) pinMode(KP_COLS[c], INPUT_PULLUP);

  Serial.begin(115200);
  delay(300);
  Serial.println();
  Serial.println("=== KHOA BAO MAT - FIRMWARE GIAI DOAN 2 (GHEP DOI AN TOAN) ===");
  store.begin();
  Serial.printf("[KHOA] Da ghep doi %d dien thoai\n", store.count());
  chooseButton();

  BLEDevice::init(LOCK_BLE_NAME);
  BLEDevice::setMTU(247);
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());
  server->advertiseOnDisconnect(true);  // thu vien tu quang ba lai khi mat ket noi
  BLEService *service = server->createService(SERVICE_UUID);
  BLECharacteristic *cmdChar = service->createCharacteristic(CMD_UUID, BLECharacteristic::PROPERTY_WRITE);
  cmdChar->setCallbacks(new CmdCallbacks());
  evtChar = service->createCharacteristic(EVT_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  evtChar->addDescriptor(new BLE2902());
  service->start();
  BLEAdvertising *adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();
  Serial.printf("[BLE] Dang quang ba '%s', dia chi %s\n", LOCK_BLE_NAME, BLEDevice::getAddress().toString().c_str());
  beep(60);
}

void loop() {
  uint32_t now = millis();

  if (rxReady) {
    uint8_t f[sizeof(rxBuf)];
    size_t n = rxLen;
    memcpy(f, rxBuf, n);
    rxReady = false;
    handleFrame(f, n);
  }
  if (clientDropped) {
    clientDropped = false;
    nonceValid = false;
    if (pend.active) endPairing(0xFE);  // app ngat ket noi giua chung -> huy ghep doi
  }
  static uint32_t lastConnLog = 0, loggedConnects = 0, loggedDrops = 0;
  if (now - lastConnLog >= 1000 && (connectCount != loggedConnects || dropCount != loggedDrops)) {
    Serial.printf("[BLE] %lu lan ket noi, %lu lan ngat (1 giay qua) - may %02x:%02x:%02x:%02x:%02x:%02x, ly do ngat 0x%02x\n",
                  (unsigned long)(connectCount - loggedConnects), (unsigned long)(dropCount - loggedDrops),
                  lastPeer[0], lastPeer[1], lastPeer[2], lastPeer[3], lastPeer[4], lastPeer[5], lastDropReason);
    loggedConnects = connectCount;
    loggedDrops = dropCount;
    lastConnLog = now;
  }

  pollButton(now);
  pollKeypad(now);

  if (relayOffAt && (int32_t)(now - relayOffAt) >= 0) {
    setRelay(false);
    Serial.println("[KHOA] Tu dong khoa lai");
  }

  if (pairingMode) {
    if ((int32_t)(now - pairDeadline) >= 0) {
      if (pend.active) endPairing(PAIR_TIMEOUT);
      else { pairingMode = false; Serial.println("[GHEP DOI] Het 60 giay - dong che do ghep doi"); }
      digitalWrite(LED_GREEN, relayOn ? HIGH : LOW);
    } else if (!relayOn) {
      digitalWrite(LED_GREEN, (now / 250) % 2);  // nhay xanh khi dang cho ghep doi
    }
  }
  delay(2);
}
