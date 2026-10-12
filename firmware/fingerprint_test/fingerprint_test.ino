// Test cam bien van tay AS608 - khoa bao mat ESP32
// Day noi: xem SO_DO_NOI_DAY.md, muc 5 (Van tay AS608)
//   AS608 TX -> GPIO16 (RX2), AS608 RX -> GPIO17 (TX2), V+ -> 3.3V, GND
// Serial: 115200 baud

#include <Adafruit_Fingerprint.h>

#define FP_RX 16  // ESP32 nhan  <- TX cua AS608
#define FP_TX 17  // ESP32 gui   -> RX cua AS608

Adafruit_Fingerprint finger(&Serial2);

const uint32_t BAUDS[] = {57600, 9600, 19200, 38400, 115200};  // 57600 la mac dinh cua AS608
bool sensorOk = false;

bool connectSensor() {
  for (uint32_t baud : BAUDS) {
    Serial2.begin(baud, SERIAL_8N1, FP_RX, FP_TX);
    finger.begin(baud);
    delay(100);
    if (finger.verifyPassword()) {
      Serial.printf("[AS608] Ket noi OK o toc do %lu baud\n", baud);
      return true;
    }
  }
  Serial.println("[AS608] LOI: khong ket noi duoc cam bien van tay.");
  Serial.println("[AS608]  - Kiem tra TX/RX phai DAU CHEO: TX(AS608)->S cum RX2, RX(AS608)->S cum TX2");
  Serial.println("[AS608]  - Kiem tra V+ -> V cum RX2 (3.3V), GND -> G cum TX2, den xanh tren cam bien co nhay khi cap dien");
  return false;
}

void printInfo() {
  if (finger.getParameters() == FINGERPRINT_OK) {
    Serial.printf("[AS608] Dung luong: %u mau | Muc bao mat: %u | Dia chi: 0x%08lX\n",
                  finger.capacity, finger.security_level, (unsigned long)finger.device_addr);
  }
  if (finger.getTemplateCount() == FINGERPRINT_OK) {
    Serial.printf("[AS608] So van tay da dang ky: %u\n", finger.templateCount);
  }
}

// Doi ngon tay: chup anh -> trich dac trung -> tim trong bo nho cam bien
void scanFinger() {
  uint8_t p = finger.getImage();
  if (p == FINGERPRINT_NOFINGER) return;
  if (p != FINGERPRINT_OK) {
    Serial.printf("[VAN TAY] Loi chup anh (ma 0x%02X), thu dat lai ngon tay\n", p);
    delay(500);
    return;
  }
  Serial.println("[VAN TAY] Phat hien ngon tay, da chup anh");

  p = finger.image2Tz();
  if (p == FINGERPRINT_IMAGEMESS) {
    Serial.println("[VAN TAY] Anh bi nhoe - lau sach mat cam bien / ngon tay roi thu lai");
  } else if (p == FINGERPRINT_FEATUREFAIL || p == FINGERPRINT_INVALIDIMAGE) {
    Serial.println("[VAN TAY] Khong trich duoc dac trung - dat ngon tay phang va day hon");
  } else if (p != FINGERPRINT_OK) {
    Serial.printf("[VAN TAY] Loi xu ly anh (ma 0x%02X)\n", p);
  } else {
    Serial.println("[VAN TAY] Doc van tay tot (anh ro, trich duoc dac trung)");
    p = finger.fingerSearch();
    if (p == FINGERPRINT_OK) {
      Serial.printf("[VAN TAY] KHOP: ID #%u, do tin cay %u\n", finger.fingerID, finger.confidence);
    } else if (p == FINGERPRINT_NOTFOUND) {
      Serial.println("[VAN TAY] Chua dang ky - van tay nay khong co trong bo nho");
    } else {
      Serial.printf("[VAN TAY] Loi tim kiem (ma 0x%02X)\n", p);
    }
  }

  // Doi nhac ngon tay ra truoc khi quet lan tiep
  while (finger.getImage() != FINGERPRINT_NOFINGER) delay(50);
  Serial.println("[VAN TAY] Da nhac tay. San sang quet lan tiep...");
}

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println();
  Serial.println("=== KHOA BAO MAT - TEST VAN TAY AS608 ===");

  sensorOk = connectSensor();
  if (sensorOk) {
    printInfo();
    Serial.println("[AS608] San sang. Hay dat ngon tay len cam bien...");
  }
}

void loop() {
  if (!sensorOk) {
    // Thu ket noi lai moi 5 giay (vd. sau khi sua day)
    delay(5000);
    sensorOk = connectSensor();
    if (sensorOk) {
      printInfo();
      Serial.println("[AS608] San sang. Hay dat ngon tay len cam bien...");
    }
    return;
  }
  scanFinger();
  delay(50);
}
