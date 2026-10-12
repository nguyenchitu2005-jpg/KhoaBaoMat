// Test ban phim 4x4 theo tung hang - khoa bao mat ESP32
// Day noi: xem SO_DO_NOI_DAY.md, muc 6 (Ban phim 4x4)
//   R1..R4 -> GPIO13, 14, 27, 26   |   C1..C4 -> GPIO25, 33, 32, 21
// Serial: 115200 baud
//
// Cach test: bam het 4 phim cua hang dang yeu cau (thu tu nao cung duoc),
// xong hang do moi chuyen sang hang tiep theo. Bam phim khac hang se bi bao SAI.

const byte ROWS = 4, COLS = 4;
const byte rowPins[ROWS] = {13, 14, 27, 26};
const byte colPins[COLS] = {25, 33, 32, 21};
const char keys[ROWS][COLS] = {
  {'1', '2', '3', 'A'},
  {'4', '5', '6', 'B'},
  {'7', '8', '9', 'C'},
  {'*', '0', '#', 'D'},
};

const unsigned long DEBOUNCE_MS = 30;

bool stableState[ROWS][COLS];
bool lastRaw[ROWS][COLS];
unsigned long changedAt[ROWS][COLS];

int currentRow = 0;          // hang dang kiem tra (0..3), 4 = da xong
bool rowDone[COLS];          // phim nao cua hang hien tai da bam
int rowErrors[ROWS];         // so lan bam nham khi dang test hang do

// Chi keo 1 hang xuong LOW, cac hang khac de tha noi (INPUT) de khong bi chap khi bam 2 phim
void selectRow(int r) {
  for (int i = 0; i < ROWS; i++) pinMode(rowPins[i], INPUT);
  if (r >= 0) {
    pinMode(rowPins[r], OUTPUT);
    digitalWrite(rowPins[r], LOW);
  }
}

bool readKey(int r, int c) {
  selectRow(r);
  delayMicroseconds(10);
  return digitalRead(colPins[c]) == LOW;
}

void printRowPrompt() {
  Serial.printf("[HANG %d] Bam cac phim: ", currentRow + 1);
  for (int c = 0; c < COLS; c++) { Serial.print(keys[currentRow][c]); Serial.print(' '); }
  Serial.printf("(R%d = GPIO%d)\n", currentRow + 1, rowPins[currentRow]);
}

void printRowRemaining() {
  Serial.printf("[HANG %d] Con lai: ", currentRow + 1);
  for (int c = 0; c < COLS; c++)
    if (!rowDone[c]) { Serial.print(keys[currentRow][c]); Serial.print(' '); }
  Serial.println();
}

void startRow(int r) {
  currentRow = r;
  for (int c = 0; c < COLS; c++) rowDone[c] = false;
  if (r < ROWS) printRowPrompt();
}

void printSummary() {
  Serial.println("[KET QUA] ===== TONG KET =====");
  for (int r = 0; r < ROWS; r++) {
    Serial.printf("[KET QUA] Hang %d (", r + 1);
    for (int c = 0; c < COLS; c++) Serial.print(keys[r][c]);
    Serial.printf("): OK, bam nham %d lan\n", rowErrors[r]);
  }
  Serial.println("[KEYPAD] HOAN TAT: ca 4 hang deu hoat dong tot!");
}

void onKeyPressed(int r, int c) {
  if (currentRow >= ROWS) {
    Serial.printf("[PHIM] '%c' (R%d-C%d)\n", keys[r][c], r + 1, c + 1);
    return;
  }
  if (r != currentRow) {
    rowErrors[currentRow]++;
    Serial.printf("[SAI] '%c' thuoc hang %d (R%d-C%d), dang test hang %d -> neu ban da bam phim cua hang %d thi day R%d/R%d bi trao\n",
                  keys[r][c], r + 1, r + 1, c + 1, currentRow + 1, currentRow + 1, currentRow + 1, r + 1);
    return;
  }
  if (rowDone[c]) {
    Serial.printf("[PHIM] '%c' - da bam roi\n", keys[r][c]);
    return;
  }
  rowDone[c] = true;
  Serial.printf("[DUNG] '%c'  (R%d-C%d, GPIO%d-GPIO%d)\n", keys[r][c], r + 1, c + 1, rowPins[r], colPins[c]);

  for (int i = 0; i < COLS; i++) if (!rowDone[i]) { printRowRemaining(); return; }

  Serial.printf("[HANG %d] OK - du 4 phim\n", currentRow + 1);
  startRow(currentRow + 1);
  if (currentRow >= ROWS) printSummary();
}

// Kiem tra luc khoi dong: khong hang nao duoc chon ma cot van LOW -> cot bi chap GND;
// chon 1 hang ma da co phim LOW -> phim bi ket hoac 2 day bi cham nhau.
bool selfTest() {
  bool ok = true;
  selectRow(-1);
  delayMicroseconds(10);
  for (int c = 0; c < COLS; c++) {
    if (digitalRead(colPins[c]) == LOW) {
      Serial.printf("[KEYPAD] LOI: cot C%d (GPIO%d) bi chap xuong GND\n", c + 1, colPins[c]);
      ok = false;
    }
  }
  for (int r = 0; r < ROWS; r++)
    for (int c = 0; c < COLS; c++)
      if (readKey(r, c)) {
        Serial.printf("[KEYPAD] LOI: phim '%c' (R%d-C%d) dang bi nhan/ket luc khoi dong\n", keys[r][c], r + 1, c + 1);
        ok = false;
      }
  selectRow(-1);
  return ok;
}

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println();
  Serial.println("=== KHOA BAO MAT - TEST BAN PHIM THEO TUNG HANG ===");

  for (int c = 0; c < COLS; c++) pinMode(colPins[c], INPUT_PULLUP);
  selectRow(-1);

  if (selfTest()) Serial.println("[KEYPAD] Kiem tra day: OK, khong co phim ket / chap mach");
  startRow(0);
}

void loop() {
  unsigned long now = millis();
  for (int r = 0; r < ROWS; r++) {
    for (int c = 0; c < COLS; c++) {
      bool raw = readKey(r, c);
      if (raw != lastRaw[r][c]) {
        lastRaw[r][c] = raw;
        changedAt[r][c] = now;
      }
      if (raw != stableState[r][c] && now - changedAt[r][c] >= DEBOUNCE_MS) {
        stableState[r][c] = raw;
        if (raw) onKeyPressed(r, c);
      }
    }
  }
  selectRow(-1);
  delay(5);
}
