// Chan doan nut nhan: do DIEN AP cung luc 4 chan chi-doc 34, 35, 36(VP), 39(VN)
// de biet day nut dang cam vao chan nao va co dien tro keo len 10k chua.
//   Nha nut dung:  ~3300 mV, dung yen       Nhan nut dung: ~0 mV, dung yen
//   Tha noi:       nhay lung tung 140..3165 mV (hung nhieu dien luoi)
// Serial: 115200 baud

const int PINS[] = {34, 35, 36, 39};
const char *NAMES[] = {"D34", "D35", "VP36", "VN39"};
const int N = 4;

void setup() {
  pinMode(22, OUTPUT);
  digitalWrite(22, LOW);  // relay TAT trong luc chan doan
  Serial.begin(115200);
  delay(300);
  analogReadResolution(12);
  for (int i = 0; i < N; i++) analogSetPinAttenuation(PINS[i], ADC_11db);
  Serial.println();
  Serial.println("=== CHAN DOAN NUT: DO 4 CHAN 34/35/36/39 ===");
  Serial.println("[NUT] Lan luot: KHONG bam 5 giay -> BAM GIU 5 giay -> tha ra");
}

void loop() {
  uint32_t mn[N], mx[N], sum[N];
  for (int i = 0; i < N; i++) { mn[i] = 9999; mx[i] = 0; sum[i] = 0; }
  int samples = 0;
  unsigned long start = millis();
  while (millis() - start < 700) {
    for (int i = 0; i < N; i++) {
      uint32_t mv = analogReadMilliVolts(PINS[i]);
      sum[i] += mv;
      if (mv < mn[i]) mn[i] = mv;
      if (mv > mx[i]) mx[i] = mv;
    }
    samples++;
    delay(2);
  }
  Serial.print("[NUT]");
  for (int i = 0; i < N; i++) {
    uint32_t avg = sum[i] / samples;
    const char *st = (mx[i] - mn[i] > 600) ? "noi" : (avg > 2800 ? "CAO" : (avg < 300 ? "THAP" : "giua"));
    Serial.printf(" %s=%4lumV(%s)", NAMES[i], (unsigned long)avg, st);
  }
  Serial.println();
}
