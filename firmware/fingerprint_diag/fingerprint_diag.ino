// Chan doan ket noi AS608: thu ca 2 chieu TX/RX (doi chan bang phan mem) x cac toc do baud,
// va kiem tra muc dien tren 2 chan de biet cam bien co duoc cap nguon / co noi day khong.
// Serial: 115200 baud

#include <Adafruit_Fingerprint.h>

const int PIN_A = 16;  // S cum RX2
const int PIN_B = 17;  // S cum TX2
const uint32_t BAUDS[] = {57600, 9600, 19200, 38400, 115200};

Adafruit_Fingerprint finger(&Serial2);

bool tryCombo(int rx, int tx, uint32_t baud) {
  Serial2.end();
  Serial2.begin(baud, SERIAL_8N1, rx, tx);
  finger.begin(baud);
  delay(100);
  while (Serial2.available()) Serial2.read();
  return finger.verifyPassword();
}

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println();
  Serial.println("=== CHAN DOAN AS608 ===");

  // 1. Muc dien khi nghi: chan TX cua AS608 (khi co nguon) giu muc HIGH ~3.3V
  pinMode(PIN_A, INPUT_PULLDOWN);
  pinMode(PIN_B, INPUT_PULLDOWN);
  delay(20);
  int a = digitalRead(PIN_A), b = digitalRead(PIN_B);
  Serial.printf("[DIAG] Muc dien (co dien tro keo xuong): GPIO16=%s, GPIO17=%s\n", a ? "HIGH" : "LOW", b ? "HIGH" : "LOW");
  if (!a && !b) {
    Serial.println("[DIAG] => Ca 2 chan deu LOW: TX cua AS608 khong dua ra tin hieu -> nhieu kha nang cam bien CHUA CO NGUON (V+/GND) hoac day tin hieu chua cam.");
  } else if (!a && b) {
    Serial.println("[DIAG] => GPIO17 HIGH, GPIO16 LOW: co ve TX cua AS608 dang cam vao TX2 (cum TX2) -> day TX/RX bi CAM THANG, chua dau cheo.");
  } else if (a && !b) {
    Serial.println("[DIAG] => GPIO16 HIGH: TX cua AS608 dang o RX2 dung vi tri, cam bien co nguon.");
  } else {
    Serial.println("[DIAG] => Ca 2 chan HIGH: ca 2 day deu co dien ap.");
  }

  // 2. Thu tat ca to hop chan x baud
  struct { int rx, tx; const char *name; } combos[] = {
    {PIN_A, PIN_B, "DAU CHEO dung so do (RX=16, TX=17)"},
    {PIN_B, PIN_A, "TRAO (RX=17, TX=16)"},
  };
  bool found = false;
  for (auto &cb : combos) {
    for (uint32_t baud : BAUDS) {
      if (tryCombo(cb.rx, cb.tx, baud)) {
        Serial.printf("[DIAG] TIM THAY cam bien: %s, %lu baud\n", cb.name, baud);
        found = true;
        if (cb.rx == PIN_B) {
          Serial.println("[DIAG] => Day TX/RX cua AS608 dang bi cam NGUOC. Hay doi cho 2 day: TX(AS608)->S cum RX2, RX(AS608)->S cum TX2.");
        } else {
          Serial.println("[DIAG] => Day dung. Neu test truoc loi, co the do tiep xuc chap chon - an chat lai day.");
        }
        break;
      }
    }
    if (found) break;
  }
  if (!found) {
    Serial.println("[DIAG] KHONG tim thay cam bien o ca 2 chieu va 5 toc do baud.");
    Serial.println("[DIAG] => Kiem tra nguon: V+ -> V cum RX2, GND -> G cum TX2; den xanh duoi mat kinh cam bien phai loe sang khi vua cap dien.");
    Serial.println("[DIAG] => Kiem tra thu tu day tren dau cam AS608 (doc nhan V+, TX, RX, GND tren mach cam bien).");
  }
  Serial.println("[DIAG] HOAN TAT: chan doan xong");
}

void loop() {}
