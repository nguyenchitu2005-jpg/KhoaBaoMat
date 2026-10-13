// Firmware khoa thong minh - GIAI DOAN 3: BLE + ghep doi + the RFID + van tay + ma PIN + nhat ky + lenh quan ly
//
// Mo cua: app (sinh trac hoc) | the RFID da dang ky | van tay da dang ky | ma PIN + # | nut trong nha
// Ban phim: go ma PIN roi bam # (bam * de xoa). Sai 5 lan -> khoa ban phim 5 phut.
// Ghep doi dien thoai moi:
//   1. Giu NUT TRONG NHA 5 giay -> LED xanh nhay, khoa mo che do ghep doi 60 giay
//      (nut trong nha = GPIO34 neu co dien tro keo len 10k, neu khong thi la nut BOOT tren mach ESP32)
//   2. App gui khoa cong khai X25519 -> khoa tra khoa cong khai cua no -> 2 ben tinh cung khoa AES + ma 6 so
//   3. Go ma 6 so hien tren app vao ban phim cua khoa (tu xac nhan khi du 6 so, hoac bam #; bam * de xoa)
// Nut trong nha: bam nhanh = mo cua | giu 5 giay = ghep doi | giu 15 giay = XOA het dien thoai, the, van tay, PIN
// Lenh quan ly (chi admin = dien thoai ghep doi dau tien): xem config.h. Dinh dang goi: KIEN_TRUC_APP.md muc 4.
// Serial: 115200 baud

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLE2902.h>
#include <SPI.h>
#include <MFRC522.h>
#include <Adafruit_Fingerprint.h>
#include "config.h"
#include "crypto_util.h"
#include "storage.h"
#include "access_store.h"
#include "access_log.h"

PhoneStore store;
AccessStore acl;
AccessLog accessLog;
MFRC522 rfid(RC522_SS, RC522_RST);
Adafruit_Fingerprint finger(&Serial2);
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

// ---- Cam bien ----
bool rfidOk = false;
bool fpOk = false;
bool fpWaitLift = false;  // da xu ly ngon tay nay roi, cho nhac tay ra moi doc tiep

// ---- Dang ky the / van tay dang cho (cmd = 0: khong co) - phan hoi duoc gui khi xong hoac het gio ----
struct {
  uint8_t cmd;
  uint8_t phoneId;
  uint32_t counter;
  uint32_t deadline;
  uint8_t step;      // van tay: 0 = cho dat tay lan 1, 1 = cho nhac tay, 2 = cho dat tay lan 2
  uint8_t fingerId;
} job;

// ---- Ma PIN dang go ----
char pinBuf[PIN_MAX_LEN + 1];  // du 1 o: go qua 8 so thi chac chan sai
uint8_t pinLen = 0;
uint32_t pinLastKey = 0;
uint8_t pinWrong = 0;  // ponytail: chi luu trong RAM, mat dien la ve 0; luu NVS neu ke gian ngat duoc nguon tu ngoai cua
bool pinLocked = false;
uint32_t pinLockUntil = 0;

// ---- Nut ----
int buttonPin = BUTTON_EXT;

static uint32_t be32(const uint8_t *b) {
  return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
}
static void putBe32(uint8_t *b, uint32_t v) {
  b[0] = v >> 24; b[1] = v >> 16; b[2] = v >> 8; b[3] = v;
}

// ======================== Phan hoi ra ngoai ========================
void sendFrame(const uint8_t *data, size_t len) {
  evtChar->setValue(data, len);
  evtChar->notify();
}

void beep(int ms, int freq = 2700) {
  tone(BUZZER, freq, ms);
  delay(ms + 30);
}

void setRelay(bool on, uint32_t holdMs = UNLOCK_MS) {
  digitalWrite(RELAY_PIN, on ? RELAY_ON : !RELAY_ON);
  relayOn = on;
  relayOffAt = on ? millis() + holdMs : 0;
  digitalWrite(LED_GREEN, on ? HIGH : LOW);
}

void flashRed(int ms = 400) {
  digitalWrite(LED_RED, HIGH);
  beep(ms, 900);
  digitalWrite(LED_RED, LOW);
}

// method = LOG_APP / LOG_CARD / ..., whoId = so dien thoai / chi so the / ID van tay
void unlockNow(const char *who, uint8_t method, uint8_t whoId, uint32_t holdMs = UNLOCK_MS) {
  setRelay(true, holdMs);
  unlockCount++;
  accessLog.add(method, whoId, LOG_OK);
  Serial.printf("[KHOA] MO - %s #%u (lan %lu)\n", who, whoId, (unsigned long)unlockCount);
  beep(80);
}

void deny(const char *why, uint8_t method, uint8_t result, const uint8_t *extra = nullptr, size_t extraLen = 0) {
  accessLog.add(method, 0, result, extra, extraLen);
  Serial.printf("[KHOA] TU CHOI - %s\n", why);
  flashRed();
}

// ======================== Lenh da ma hoa ========================
// Phan hoi: [0x82][keyId][IV 12][AES(cmd, result, counter 4B, payload)][tag 16]
void sendSealedReply(Phone *p, uint8_t cmd, uint8_t result, uint32_t counter,
                     const uint8_t *payload = nullptr, size_t payloadLen = 0) {
  uint8_t plain[6 + MAX_REPLY_PAYLOAD];
  if (payloadLen > MAX_REPLY_PAYLOAD) payloadLen = MAX_REPLY_PAYLOAD;
  plain[0] = cmd;
  plain[1] = result;
  putBe32(plain + 2, counter);
  if (payloadLen) memcpy(plain + 6, payload, payloadLen);
  size_t plainLen = 6 + payloadLen;

  uint8_t out[2 + 12 + sizeof(plain) + 16];
  out[0] = FRAME_SEALED_REPLY;
  out[1] = p->id;
  if (!gcmSeal(p->key, p->id, plain, plainLen, out + 2, out + 14, out + 14 + plainLen)) return;
  sendFrame(out, 14 + plainLen + 16);
}

// Ket thuc viec dang ky dang cho: gui phan hoi cho dien thoai da ra lenh
void finishJob(uint8_t result, const uint8_t *payload = nullptr, size_t payloadLen = 0) {
  Phone *p = store.find(job.phoneId);
  if (p && clientConnected) sendSealedReply(p, job.cmd, result, job.counter, payload, payloadLen);
  Serial.printf("[DANG KY] %s xong, ket qua 0x%02X\n", job.cmd == CMD_ENROLL_CARD ? "The" : "Van tay", result);
  job.cmd = 0;
  fpWaitLift = true;  // ngon tay vua dang ky con tren cam bien -> khong coi la 1 lan mo cua
  if (result == RES_OK) { beep(100); delay(80); beep(100); }
  else flashRed();
}

void sendProgress(uint8_t step) {
  uint8_t out[3] = {FRAME_PROGRESS, job.cmd, step};
  if (clientConnected) sendFrame(out, sizeof(out));
}

// id = 0xFF: xoa het. Xoa ca mau trong AS608 lan danh dau trong NVS.
bool deleteFinger(uint8_t id) {
  if (id == 0xFF) {
    if (fpOk) finger.emptyDatabase();
    acl.clearFingers();
    return true;
  }
  if (!acl.hasFinger(id)) return false;
  if (fpOk) finger.deleteModel(id);
  acl.setFinger(id, false);  // NVS la noi quyet dinh: mau con sot trong AS608 cung khong mo duoc cua
  return true;
}

// Lenh quan ly (admin). arg = payload cua lenh.
void handleAdmin(Phone *p, uint8_t cmd, uint32_t counter, const uint8_t *arg, size_t argLen) {
  switch (cmd) {
    case CMD_GET_LOGS: {
      if (argLen != 4) { sendSealedReply(p, cmd, RES_BAD_ARG, counter); break; }
      uint32_t total = accessLog.total();
      uint32_t first = be32(arg);
      uint32_t oldest = total > LOG_CAPACITY ? total - LOG_CAPACITY : 0;
      if (first < oldest) first = oldest;
      LogRecord recs[LOGS_PER_REPLY];
      int n = accessLog.read(first, recs, LOGS_PER_REPLY);
      uint8_t out[9 + sizeof(recs)];
      putBe32(out, total);
      putBe32(out + 4, first);
      out[8] = n;
      memcpy(out + 9, recs, n * sizeof(LogRecord));
      sendSealedReply(p, cmd, RES_OK, counter, out, 9 + n * sizeof(LogRecord));
      break;
    }
    case CMD_ENROLL_CARD:
    case CMD_ENROLL_FINGER: {
      bool isCard = cmd == CMD_ENROLL_CARD;
      int fid = isCard ? 0 : acl.freeFingerId();
      uint8_t err = job.cmd ? RES_BUSY
                    : !(isCard ? rfidOk : fpOk) ? RES_NO_SENSOR
                    : (isCard ? acl.cardCount() >= MAX_CARDS : fid < 0) ? RES_FULL
                    : RES_OK;
      if (err != RES_OK) { sendSealedReply(p, cmd, err, counter); break; }
      job.cmd = cmd;
      job.phoneId = p->id;
      job.counter = counter;
      job.step = 0;
      job.fingerId = fid;
      job.deadline = millis() + (isCard ? ENROLL_CARD_MS : ENROLL_FINGER_MS);
      Serial.println(isCard ? "[DANG KY] Dua THE MOI lai gan dau doc (15 giay)"
                            : "[DANG KY] Dat NGON TAY len cam bien (2 lan)");
      beep(200, 2000);
      break;  // phan hoi gui sau, trong finishJob()
    }
    case CMD_DELETE_CARD:
      sendSealedReply(p, cmd, argLen == 1 && acl.deleteCard(arg[0]) ? RES_OK : RES_BAD_ARG, counter);
      break;
    case CMD_DELETE_FINGER:
      sendSealedReply(p, cmd, argLen == 1 && deleteFinger(arg[0]) ? RES_OK : RES_BAD_ARG, counter);
      break;
    case CMD_SET_PIN: {
      // [do dai][cac chu so ASCII]; do dai 0 = tat PIN
      bool ok = argLen >= 1 && argLen == (size_t)arg[0] + 1 &&
                (arg[0] == 0 || (arg[0] >= PIN_MIN_LEN && arg[0] <= PIN_MAX_LEN));
      for (size_t i = 1; ok && i < argLen; i++) ok = arg[i] >= '0' && arg[i] <= '9';
      if (!ok) { sendSealedReply(p, cmd, RES_BAD_ARG, counter); break; }
      acl.setPin((const char *)arg + 1, arg[0]);
      pinWrong = 0;
      pinLocked = false;
      Serial.println(arg[0] ? "[PIN] Da dat ma PIN moi" : "[PIN] Da tat ma PIN");
      sendSealedReply(p, cmd, RES_OK, counter);
      break;
    }
    case CMD_SET_GUEST_PIN: {
      // [het han unix 4B][do dai][cac chu so ASCII]; do dai 0 = xoa ma khach
      bool ok = argLen >= 5 && argLen == (size_t)arg[4] + 5 &&
                (arg[4] == 0 || (arg[4] >= PIN_MIN_LEN && arg[4] <= PIN_MAX_LEN));
      for (size_t i = 5; ok && i < argLen; i++) ok = arg[i] >= '0' && arg[i] <= '9';
      // gio cua khoa vua duoc dong bo tu chinh lenh nay
      if (ok && arg[4]) ok = be32(arg) > accessLog.nowUnix();
      if (!ok) { sendSealedReply(p, cmd, RES_BAD_ARG, counter); break; }
      acl.setGuestPin((const char *)arg + 5, arg[4], be32(arg));
      Serial.println(arg[4] ? "[PIN] Da dat ma khach" : "[PIN] Da xoa ma khach");
      sendSealedReply(p, cmd, RES_OK, counter);
      break;
    }
    case CMD_LIST_PHONES: {
      uint8_t out[1 + 2 * MAX_PHONES] = {0};
      for (uint8_t id = 1; id <= MAX_PHONES; id++) {
        Phone *q = store.find(id);
        if (!q) continue;
        out[1 + 2 * out[0]] = id;
        out[2 + 2 * out[0]] = q->role;
        out[0]++;
      }
      sendSealedReply(p, cmd, RES_OK, counter, out, 1 + 2 * out[0]);
      break;
    }
    case CMD_REVOKE_PHONE: {
      // Tra loi truoc khi xoa. Khong cho tu thu hoi minh: khoa se khong con admin nao.
      bool ok = argLen == 1 && arg[0] != p->id && store.find(arg[0]);
      sendSealedReply(p, cmd, ok ? RES_OK : RES_BAD_ARG, counter);
      if (ok) {
        store.remove(arg[0]);
        Serial.printf("[KHOA] Da thu hoi dien thoai #%u\n", arg[0]);
      }
      break;
    }
    case CMD_LIST_ACCESS: {
      // [co PIN][mat na van tay 4B][han ma khach 4B][so the][{chi so, do dai, UID}...] - the nao khong vua goi thi bi cat
      uint8_t out[MAX_REPLY_PAYLOAD];
      size_t n = 10;
      out[0] = acl.pinSet();
      putBe32(out + 1, acl.fingerMask());
      putBe32(out + 5, acl.guestExpiry());
      out[9] = 0;
      for (int i = 0; i < MAX_CARDS; i++) {
        const Card &c = acl.card(i);
        if (!c.active || n + 2 + c.uidLen > sizeof(out)) continue;
        out[n++] = i;
        out[n++] = c.uidLen;
        memcpy(out + n, c.uid, c.uidLen);
        n += c.uidLen;
        out[9]++;
      }
      sendSealedReply(p, cmd, RES_OK, counter, out, n);
      break;
    }
    default:
      sendSealedReply(p, cmd, RES_UNKNOWN_CMD, counter);
  }
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
  uint32_t counter = be32(plain + 1);
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
  accessLog.syncTime(be32(plain + 13));  // lenh da xac thuc -> tin duoc gio cua dien thoai

  switch (cmd) {
    case CMD_UNLOCK:
      sendSealedReply(p, cmd, RES_OK, counter);
      unlockNow("app, dien thoai", LOG_APP, p->id);
      break;
    case CMD_LOCK:
      setRelay(false);
      Serial.printf("[KHOA] DONG - app, dien thoai #%u\n", p->id);
      sendSealedReply(p, cmd, RES_OK, counter);
      break;
    case CMD_STATUS: {
      uint8_t st[13] = {(uint8_t)relayOn};
      putBe32(st + 1, millis() / 1000);
      putBe32(st + 5, unlockCount);
      st[9] = store.count();
      st[10] = pairingMode;
      st[11] = p->role;
      st[12] = pinLocked;
      sendSealedReply(p, cmd, RES_OK, counter, st, sizeof(st));
      break;
    }
    default:
      if (cmd >= CMD_GET_LOGS && p->role != ROLE_ADMIN) {
        Serial.printf("[BLE] TU CHOI: dien thoai #%u khong phai admin (lenh 0x%02X)\n", p->id, cmd);
        sendSealedReply(p, cmd, RES_DENIED, counter);
      } else {
        handleAdmin(p, cmd, counter, plain + 17, ctLen - 17);
      }
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

void onPairKey(char k) {
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

// ======================== Ma PIN ========================
void onPinKey(char k) {
  if (pinLocked) { flashRed(150); return; }
  tone(BUZZER, 3500, 40);
  if (k >= '0' && k <= '9') {
    if (pinLen < sizeof(pinBuf)) pinBuf[pinLen++] = k;
    pinLastKey = millis();
    return;
  }
  if (k == '*') { pinLen = 0; return; }
  if (k != '#' || pinLen == 0) return;

  bool ok = acl.checkPin(pinBuf, pinLen);
  bool guest = !ok && acl.checkGuestPin(pinBuf, pinLen, accessLog.nowUnix());
  pinLen = 0;
  memset(pinBuf, 0, sizeof(pinBuf));
  if (ok || guest) {
    pinWrong = 0;
    unlockNow(guest ? "ma khach" : "ma PIN", LOG_PIN, guest);  // nhat ky: ai = 1 la ma khach
  } else if (!acl.pinSet() && !acl.guestSet()) {
    Serial.println("[PIN] Chua dat ma PIN (dat trong app)");
    flashRed();
  } else if (++pinWrong >= PIN_MAX_WRONG) {
    pinWrong = 0;
    pinLocked = true;
    pinLockUntil = millis() + PIN_LOCKOUT_MS;
    accessLog.add(LOG_PIN, 0, LOG_PIN_LOCKOUT);
    Serial.println("[PIN] Sai 5 lan - KHOA BAN PHIM 5 phut");
    for (int i = 0; i < 3; i++) flashRed(500);
  } else {
    deny("sai ma PIN", LOG_PIN, LOG_WRONG_PIN);
  }
}

void onKeyPressed(char k) {
  if (pend.active) onPairKey(k);  // dang ghep doi: ban phim dung de go ma 6 so
  else onPinKey(k);
}

// ======================== The RFID ========================
bool rfidAlive() {
  byte v = rfid.PCD_ReadRegister(MFRC522::VersionReg);
  return v != 0x00 && v != 0xFF;  // 0x00 / 0xFF = khong noi chuyen duoc voi RC522
}

void onCard(const uint8_t *uid, uint8_t len) {
  int idx = acl.findCard(uid, len);
  if (job.cmd == CMD_ENROLL_CARD) {
    if (idx >= 0) { finishJob(RES_EXISTS); return; }
    idx = acl.addCard(uid, len);
    if (idx < 0) { finishJob(RES_FULL); return; }
    uint8_t out[12] = {(uint8_t)idx, len};
    memcpy(out + 2, uid, len);
    finishJob(RES_OK, out, 2 + len);
    return;
  }
  if (idx >= 0) unlockNow("the", LOG_CARD, idx);
  else deny("the chua dang ky", LOG_CARD, LOG_UNKNOWN, uid, len);
}

void pollRfid(uint32_t now) {
  static uint32_t last = 0, lastCheck = 0, lastSeenAt = 0;
  static uint8_t lastUid[10], lastLen = 0;
  if (now - last < RFID_POLL_MS) return;
  last = now;
  if (now - lastCheck >= 5000) {  // phat hien long day khi dang chay
    lastCheck = now;
    bool ok = rfidAlive();
    if (!ok) rfid.PCD_Init();
    if (ok != rfidOk) Serial.println(ok ? "[RC522] Da ket noi lai" : "[RC522] Mat ket noi - kiem tra day");
    rfidOk = ok;
  }
  if (!rfidOk || !rfid.PICC_IsNewCardPresent() || !rfid.PICC_ReadCardSerial()) return;

  uint8_t len = min((size_t)rfid.uid.size, sizeof(lastUid));
  uint8_t uid[10];
  memcpy(uid, rfid.uid.uidByte, len);
  rfid.PICC_HaltA();
  rfid.PCD_StopCrypto1();

  bool same = len == lastLen && memcmp(uid, lastUid, len) == 0 && now - lastSeenAt < SAME_CARD_MS;
  memcpy(lastUid, uid, len);
  lastLen = len;
  lastSeenAt = now;
  if (!same || job.cmd == CMD_ENROLL_CARD) onCard(uid, len);
}

// ======================== Van tay ========================
// Dang ky: dat tay lan 1 -> nhac tay -> dat tay lan 2 -> ghep 2 mau va luu vao AS608
void enrollFingerStep(uint8_t img, uint32_t now) {
  switch (job.step) {
    case 0:
      if (img != FINGERPRINT_OK || finger.image2Tz(1) != FINGERPRINT_OK) return;  // anh nhoe -> cho dat lai
      if (finger.fingerSearch() == FINGERPRINT_OK && acl.hasFinger(finger.fingerID)) { finishJob(RES_EXISTS); return; }
      job.step = 1;
      job.deadline = now + ENROLL_FINGER_MS;
      sendProgress(1);
      Serial.println("[DANG KY] Da doc lan 1 - NHAC TAY ra");
      beep(80);
      break;
    case 1:
      if (img != FINGERPRINT_NOFINGER) return;
      job.step = 2;
      job.deadline = now + ENROLL_FINGER_MS;
      sendProgress(2);
      Serial.println("[DANG KY] Dat lai CUNG NGON TAY lan 2");
      break;
    case 2: {
      if (img != FINGERPRINT_OK) return;
      uint8_t id = job.fingerId;
      bool ok = finger.image2Tz(2) == FINGERPRINT_OK && finger.createModel() == FINGERPRINT_OK &&
                finger.storeModel(id) == FINGERPRINT_OK;
      if (!ok) { finishJob(RES_ENROLL_FAIL); return; }
      acl.setFinger(id, true);
      finishJob(RES_OK, &id, 1);
    }
  }
}

void pollFinger(uint32_t now) {
  static uint32_t last = 0;
  static uint8_t skipped = 0;
  bool enrolling = job.cmd == CMD_ENROLL_FINGER;
  if (now - last < (enrolling ? 100 : FP_POLL_MS)) return;
  last = now;

  if (!fpOk) {  // thu ket noi lai khoang 10 giay 1 lan (moi lan thu chan toi 1 giay)
    if (++skipped < 10000 / FP_POLL_MS) return;
    skipped = 0;
    fpOk = finger.verifyPassword();
    if (fpOk) Serial.println("[AS608] Da ket noi lai");
    return;
  }

  uint8_t img = finger.getImage();
  if (img == FINGERPRINT_PACKETRECIEVEERR) {  // cam bien khong tra loi
    fpOk = false;
    Serial.println("[AS608] Mat ket noi - kiem tra day");
    if (enrolling) finishJob(RES_NO_SENSOR);
    return;
  }
  if (enrolling) { enrollFingerStep(img, now); return; }

  if (img == FINGERPRINT_NOFINGER) { fpWaitLift = false; return; }
  if (fpWaitLift || img != FINGERPRINT_OK) return;
  fpWaitLift = true;
  if (finger.image2Tz() != FINGERPRINT_OK) { flashRed(150); return; }  // anh nhoe: nhac tay dat lai, khong ghi nhat ky
  if (finger.fingerSearch() == FINGERPRINT_OK && acl.hasFinger(finger.fingerID)) {
    unlockNow("van tay", LOG_FINGER, finger.fingerID);
  } else {
    deny("van tay chua dang ky", LOG_FINGER, LOG_UNKNOWN);
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
      if (n != 2 || !store.find(f[1])) return;  // may la khong xin duoc nonce -> khong ghi de nonce cua may da ghep
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

// Giu nut 15 giay: ve trang thai xuat xuong (giu lai nhat ky)
void factoryReset() {
  if (pend.active) endPairing(0xFF);
  pairingMode = false;
  if (job.cmd) finishJob(RES_TIMEOUT);
  store.clear();
  deleteFinger(0xFF);
  acl.clearAll();
  pinLen = 0;
  pinWrong = 0;
  pinLocked = false;
  Serial.println("[NUT] DA XOA TAT CA dien thoai, the, van tay va ma PIN");
  for (int i = 0; i < 3; i++) { beep(300, 1500); delay(100); }
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
    if (stage == 1 && held >= HOLD_RESET_MS) { stage = 2; factoryReset(); }
  }
  if (down && !raw) {
    down = false;
    if (stage == 0 && now - downSince < 1000) {
      // Bam mot nhip: dang khoa -> mo (toi da BUTTON_OPEN_MS), dang mo -> khoa ngay
      if (relayOn) {
        setRelay(false);
        Serial.println("[KHOA] DONG - nut trong nha");
        beep(80);
      } else {
        unlockNow("nut trong nha", LOG_BUTTON, 0, BUTTON_OPEN_MS);
      }
    }
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
  Serial.println("=== KHOA BAO MAT - FIRMWARE GIAI DOAN 3 (THE, VAN TAY, PIN, NHAT KY) ===");
  store.begin();
  acl.begin();
  if (!accessLog.begin()) Serial.println("[NHAT KY] LOI: khong mo duoc LittleFS - se khong ghi nhat ky");
  Serial.printf("[KHOA] %d dien thoai, %d the, van tay 0x%08lX, PIN %s, %lu ban ghi nhat ky\n",
                store.count(), acl.cardCount(), (unsigned long)acl.fingerMask(),
                acl.pinSet() ? "da dat" : "chua dat", (unsigned long)accessLog.total());
  chooseButton();

  SPI.begin(RC522_SCK, RC522_MISO, RC522_MOSI, RC522_SS);
  rfid.PCD_Init();
  delay(50);
  rfidOk = rfidAlive();
  Serial.println(rfidOk ? "[RC522] OK" : "[RC522] LOI: khong ket noi duoc dau doc the");

  Serial2.begin(57600, SERIAL_8N1, FP_RX, FP_TX);
  finger.begin(57600);
  fpOk = finger.verifyPassword();
  Serial.println(fpOk ? "[AS608] OK" : "[AS608] LOI: khong ket noi duoc cam bien van tay");

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
    if (pend.active) endPairing(0xFE);    // app ngat ket noi giua chung -> huy ghep doi
    if (job.cmd) finishJob(RES_TIMEOUT);  // ... va huy dang ky dang cho
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
  // Dang go ma tren ban phim thi tam ngung do cam bien (moi lan do chan loop vai chuc ms -> de sot phim)
  if (job.cmd || (!pend.active && pinLen == 0)) {
    pollRfid(now);
    pollFinger(now);
  }

  if (job.cmd && (int32_t)(now - job.deadline) >= 0) finishJob(RES_TIMEOUT);
  // millis() chu khong phai now: pinLastKey duoc dat SAU now trong cung vong lap -> now - pinLastKey tran so
  if (pinLen && millis() - pinLastKey >= PIN_IDLE_MS) pinLen = 0;
  if (pinLocked && (int32_t)(now - pinLockUntil) >= 0) {
    pinLocked = false;
    Serial.println("[PIN] Mo lai ban phim");
  }

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
