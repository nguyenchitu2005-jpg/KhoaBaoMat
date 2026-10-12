// Test TOAN BO phan cung sau khi dau du day (SO_DO_NOI_DAY.md muc 1-8)
// 1) Tu kiem tra: nut, RC522, AS608, ban phim
// 2) Chay lan luot: LED xanh, LED do, buzzer, relay (khoa mo 2 giay)
// 3) Thu tu do: bam nut -> mo khoa 3s | quet the / dat van tay / bam phim -> bao tren Serial + LED + buzzer
// Bao ve chot khoa: relay mo toi da 3 giay, sau do nghi bat buoc 5 giay.
// Serial: 115200 baud

#include <SPI.h>
#include <MFRC522.h>
#include <Adafruit_Fingerprint.h>

// ---- Chan (theo SO_DO_NOI_DAY.md) ----
#define RELAY_PIN 22
#define RELAY_ON  HIGH   // doi thanh LOW neu module relay kich muc thap
#define LED_GREEN 2
#define LED_RED   15
#define BUZZER    12
#define BUTTON    34     // keo len 10k ngoai, nhan = LOW
#define RC522_SS 5
#define RC522_RST 4
#define FP_RX 16
#define FP_TX 17
const byte ROWS = 4, COLS = 4;
const byte rowPins[ROWS] = {13, 14, 27, 26};
const byte colPins[COLS] = {25, 33, 32, 21};
const char keys[ROWS][COLS] = {{'1','2','3','A'},{'4','5','6','B'},{'7','8','9','C'},{'*','0','#','D'}};

const unsigned long RELAY_MAX_MS = 3000;
const unsigned long RELAY_REST_MS = 5000;

MFRC522 rfid(RC522_SS, RC522_RST);
Adafruit_Fingerprint finger(&Serial2);
bool fpOk = false, rfidOk = false, buttonOk = false;

void relay(bool on) { digitalWrite(RELAY_PIN, on ? RELAY_ON : !RELAY_ON); }

void beep(int ms, int freq = 2700) { tone(BUZZER, freq, ms); delay(ms + 40); }

void selectRow(int r) {
  for (int i = 0; i < ROWS; i++) pinMode(rowPins[i], INPUT);
  if (r >= 0) { pinMode(rowPins[r], OUTPUT); digitalWrite(rowPins[r], LOW); }
}

char scanKeypad() {  // tra ve phim dang nhan (0 neu khong co)
  for (int r = 0; r < ROWS; r++) {
    selectRow(r);
    delayMicroseconds(10);
    for (int c = 0; c < COLS; c++)
      if (digitalRead(colPins[c]) == LOW) { selectRow(-1); return keys[r][c]; }
  }
  selectRow(-1);
  return 0;
}

// Ty le % thoi gian chan nut o muc LOW trong khoang [ms]. Nut nha + co 10k keo len -> ~0%.
int buttonLowPercent(unsigned long ms) {
  int low = 0, total = 0;
  unsigned long start = millis();
  while (millis() - start < ms) {
    if (digitalRead(BUTTON) == LOW) low++;
    total++;
    delayMicroseconds(200);
  }
  return low * 100 / total;
}

bool connectFingerprint() {
  const uint32_t bauds[] = {57600, 9600, 19200, 38400, 115200};
  for (uint32_t baud : bauds) {
    Serial2.begin(baud, SERIAL_8N1, FP_RX, FP_TX);
    finger.begin(baud);
    delay(100);
    if (finger.verifyPassword()) {
      Serial.printf("[VAN TAY] OK o %lu baud", (unsigned long)baud);
      if (finger.getTemplateCount() == FINGERPRINT_OK) Serial.printf(" - %u mau da dang ky", finger.templateCount);
      Serial.println();
      return true;
    }
  }
  Serial.println("[VAN TAY] LOI: khong ket noi AS608 - an chat 4 day V+/TX/RX/GND (TX,RX dau cheo)");
  return false;
}

void selfTest() {
  Serial.println("[TU KIEM TRA] ----------------------------");
  int lowPct = buttonLowPercent(500);
  buttonOk = lowPct <= 2;
  if (lowPct <= 2)
    Serial.printf("[NUT] OK - nha nut: LOW %d%%\n", lowPct);
  else if (lowPct >= 98)
    Serial.printf("[NUT] LOI: LOW %d%% -> nut dang bi nhan / noi nham cap chan luon thong cua nut 4 chan\n", lowPct);
  else
    Serial.printf("[NUT] LOI: LOW %d%% chap chon -> chan THA NOI: thieu dien tro 10k len duong + (day 37), hoac duong +/- breadboard chua co nguon (day 12, 13)\n", lowPct);
  if (!buttonOk) Serial.println("[NUT] => TAT chuc nang nut de bao ve chot khoa. Sua day xong bam EN/RST de test lai.");

  byte v = rfid.PCD_ReadRegister(MFRC522::VersionReg);
  rfidOk = !(v == 0x00 || v == 0xFF);
  Serial.printf("[RFID] VersionReg 0x%02X -> %s\n", v, rfidOk ? "OK" : "LOI: khong ket noi RC522");

  fpOk = connectFingerprint();

  char k = scanKeypad();
  Serial.printf("[PHIM] %s\n", k ? "LOI: co phim dang bi ket" : "OK - khong phim nao bi ket");
}

void demoOutputs() {
  Serial.println("[CHAY THU] ----------------------------");
  Serial.println("[LED] LED XANH sang 1 giay...");
  digitalWrite(LED_GREEN, HIGH); delay(1000); digitalWrite(LED_GREEN, LOW);
  Serial.println("[LED] LED DO sang 1 giay...");
  digitalWrite(LED_RED, HIGH); delay(1000); digitalWrite(LED_RED, LOW);
  Serial.println("[CORI] Buzzer keu 2 tieng...");
  beep(150); delay(150); beep(150);
  delay(500);
  Serial.println("[RELAY] Relay BAT 2 giay -> chot khoa phai MO (nghe tieng tach)...");
  relay(true); digitalWrite(LED_GREEN, HIGH);
  delay(2000);
  relay(false); digitalWrite(LED_GREEN, LOW);
  Serial.println("[RELAY] Relay TAT -> chot khoa phai DONG lai");
}

void setup() {
  // Relay TAT ngay khi khoi dong de khong cap dien lien tuc cho chot khoa
  pinMode(RELAY_PIN, OUTPUT); relay(false);
  pinMode(LED_GREEN, OUTPUT); pinMode(LED_RED, OUTPUT);
  pinMode(BUZZER, OUTPUT);
  pinMode(BUTTON, INPUT);
  for (int c = 0; c < COLS; c++) pinMode(colPins[c], INPUT_PULLUP);
  selectRow(-1);

  Serial.begin(115200);
  delay(300);
  Serial.println();
  Serial.println("=== KHOA BAO MAT - TEST TOAN BO PHAN CUNG ===");

  SPI.begin(18, 19, 23, RC522_SS);
  rfid.PCD_Init();
  delay(50);

  selfTest();
  demoOutputs();
  Serial.println("[THU TU DO] Bam NUT = mo khoa 3s | quet THE | dat VAN TAY | bam PHIM");
}

unsigned long relayOffAt = 0, relayRestUntil = 0, lastFpCheck = 0;
unsigned long btnHighSince = 0, lastLevelLog = 0;
int lowReads = 0, totalReads = 0;
bool btnArmed = false;
char lastKey = 0;

void loop() {
  unsigned long now = millis();

  // Nut: chi nhan khi truoc do da NHA (HIGH) on dinh >= 200ms -> chan "tha noi" khong tu kich lien tuc
  bool btn = buttonOk ? digitalRead(BUTTON) : HIGH;
  totalReads++;
  if (btn == LOW) lowReads++;
  if (btn == HIGH) {
    if (!btnHighSince) btnHighSince = now;
    if (now - btnHighSince >= 200) btnArmed = true;
  } else {
    btnHighSince = 0;
    if (btnArmed) {
      btnArmed = false;
      if (relayOffAt || now < relayRestUntil) {
        Serial.println("[NUT] Da bam - relay dang bat/nghi, bo qua (bao ve chot khoa)");
      } else {
        Serial.println("[NUT] Da bam -> MO khoa 3 giay");
        relay(true); digitalWrite(LED_GREEN, HIGH); beep(80);
        relayOffAt = now + RELAY_MAX_MS;
      }
    }
  }
  if (relayOffAt && now >= relayOffAt) {
    relay(false); digitalWrite(LED_GREEN, LOW);
    relayOffAt = 0;
    relayRestUntil = now + RELAY_REST_MS;
    Serial.println("[RELAY] Tu dong khoa lai (nghi 5 giay)");
  }

  // Muc dien chan nut moi 5 giay (chi in khi bat thuong)
  if (now - lastLevelLog >= 5000) {
    int pct = totalReads ? lowReads * 100 / totalReads : 0;
    if (pct > 2 && pct < 98) Serial.printf("[NUT-MUC] Chan nut chap chon: LOW %d%% -> THA NOI, kiem tra dien tro 10k\n", pct);
    lastLevelLog = now; lowReads = 0; totalReads = 0;
  }

  // Ban phim
  char k = scanKeypad();
  if (k && k != lastKey) { Serial.printf("[PHIM] '%c'\n", k); beep(40, 3500); }
  lastKey = k;

  // RFID
  if (rfidOk && rfid.PICC_IsNewCardPresent() && rfid.PICC_ReadCardSerial()) {
    Serial.print("[THE] UID:");
    for (byte i = 0; i < rfid.uid.size; i++) Serial.printf(" %02X", rfid.uid.uidByte[i]);
    Serial.println();
    digitalWrite(LED_GREEN, HIGH); beep(120); digitalWrite(LED_GREEN, LOW);
    rfid.PICC_HaltA();
    rfid.PCD_StopCrypto1();
  }

  // Van tay (kiem tra moi 300ms)
  if (fpOk && now - lastFpCheck > 300) {
    lastFpCheck = now;
    if (finger.getImage() == FINGERPRINT_OK) {
      bool good = finger.image2Tz() == FINGERPRINT_OK;
      Serial.printf("[VAN TAY] Phat hien ngon tay - %s\n", good ? "anh ro" : "anh mo, dat lai");
      digitalWrite(good ? LED_GREEN : LED_RED, HIGH); beep(good ? 120 : 400, good ? 2700 : 900);
      digitalWrite(LED_GREEN, LOW); digitalWrite(LED_RED, LOW);
      unsigned long t = millis();
      while (finger.getImage() != FINGERPRINT_NOFINGER && millis() - t < 5000) delay(50);
    }
  }
  delay(5);
}
