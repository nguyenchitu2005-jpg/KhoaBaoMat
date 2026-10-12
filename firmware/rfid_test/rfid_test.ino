// Quet the RFID bang RC522 - khoa bao mat ESP32
// Day noi: xem SO_DO_NOI_DAY.md, muc 4 (RFID RC522)
//   SDA -> GPIO5, SCK -> GPIO18, MOSI -> GPIO23, MISO -> GPIO19, RST -> GPIO4, 3.3V, GND
// Serial: 115200 baud

#include <SPI.h>
#include <MFRC522.h>

#define RC522_SS   5
#define RC522_RST  4
#define RC522_SCK  18
#define RC522_MISO 19
#define RC522_MOSI 23

MFRC522 rfid(RC522_SS, RC522_RST);

String lastUid;
unsigned long lastScanMs = 0;
const unsigned long SAME_CARD_DELAY_MS = 2000;  // bo qua cung 1 the quet lien tuc

String uidToString(const MFRC522::Uid &uid) {
  String s;
  for (byte i = 0; i < uid.size; i++) {
    if (i > 0) s += ':';
    if (uid.uidByte[i] < 0x10) s += '0';
    s += String(uid.uidByte[i], HEX);
  }
  s.toUpperCase();
  return s;
}

// Doc thanh ghi VersionReg de kiem tra day noi: 0x91/0x92 (va 0x88/0xB2 cho chip nhai) la OK,
// 0x00 hoac 0xFF nghia la ESP32 khong noi chuyen duoc voi RC522.
bool checkReader() {
  byte v = rfid.PCD_ReadRegister(MFRC522::VersionReg);
  Serial.printf("[RC522] VersionReg = 0x%02X -> ", v);
  if (v == 0x00 || v == 0xFF) {
    Serial.println("LOI: khong ket noi duoc RC522, kiem tra lai day SDA/SCK/MOSI/MISO/RST va nguon 3.3V");
    return false;
  }
  if (v == 0x91 || v == 0x92) Serial.println("OK (MFRC522 chinh hang)");
  else Serial.println("OK (chip tuong thich)");
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println();
  Serial.println("=== KHOA BAO MAT - TEST RFID RC522 ===");

  SPI.begin(RC522_SCK, RC522_MISO, RC522_MOSI, RC522_SS);
  rfid.PCD_Init();
  delay(50);

  if (checkReader()) {
    Serial.println("[RC522] San sang. Hay dua the/moc khoa lai gan dau doc...");
  }
}

void loop() {
  // Moi 5 giay kiem tra lai dau doc (phat hien long day khi dang chay)
  static unsigned long lastCheckMs = 0;
  if (millis() - lastCheckMs > 5000) {
    lastCheckMs = millis();
    byte v = rfid.PCD_ReadRegister(MFRC522::VersionReg);
    if (v == 0x00 || v == 0xFF) {
      Serial.println("[RC522] Mat ket noi! Dang khoi dong lai dau doc...");
      rfid.PCD_Init();
      checkReader();
    }
  }

  if (!rfid.PICC_IsNewCardPresent() || !rfid.PICC_ReadCardSerial()) {
    return;
  }

  String uid = uidToString(rfid.uid);
  if (uid != lastUid || millis() - lastScanMs > SAME_CARD_DELAY_MS) {
    MFRC522::PICC_Type type = rfid.PICC_GetType(rfid.uid.sak);
    Serial.printf("[THE] UID: %s | Loai: %s | %d byte\n",
                  uid.c_str(), String(rfid.PICC_GetTypeName(type)).c_str(), rfid.uid.size);
  }
  lastUid = uid;
  lastScanMs = millis();

  rfid.PICC_HaltA();
  rfid.PCD_StopCrypto1();
}
