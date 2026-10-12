// Cau hinh chung cho firmware khoa - chan GPIO theo SO_DO_NOI_DAY.md
#pragma once
#include <Arduino.h>

// ---- BLE (phai trung voi lib/core/ble/lock_protocol.dart) ----
#define LOCK_BLE_NAME "Khoabaomat"
#define SERVICE_UUID  "8a1c0001-5b7e-4e2b-9b6a-3c4d5e6f7a80"
#define CMD_UUID      "8a1c0002-5b7e-4e2b-9b6a-3c4d5e6f7a80"  // App -> Khoa (write)
#define EVT_UUID      "8a1c0003-5b7e-4e2b-9b6a-3c4d5e6f7a80"  // Khoa -> App (notify)

// ---- Chan GPIO ----
#define RELAY_PIN   22
#define RELAY_ON    HIGH  // module relay dang cam jumper H (kich muc cao)
#define LED_GREEN   2
#define LED_RED     15
#define BUZZER      12
#define BUTTON_EXT  34    // nut trong nha (can dien tro keo len 10k ngoai)
#define BUTTON_BOOT 0     // nut BOOT tren mach ESP32 - dung tam khi chua co dien tro
const uint8_t KP_ROWS[4] = {13, 14, 27, 26};
const uint8_t KP_COLS[4] = {25, 33, 32, 21};
const char KP_KEYS[4][4] = {{'1','2','3','A'},{'4','5','6','B'},{'7','8','9','C'},{'*','0','#','D'}};

// ---- Thoi gian ----
const uint32_t UNLOCK_MS      = 5000;   // relay dong 5 giay roi tu khoa
const uint32_t NONCE_TTL_MS   = 10000;
const uint32_t HOLD_PAIR_MS   = 5000;   // giu nut 5 giay -> che do ghep doi
const uint32_t HOLD_RESET_MS  = 15000;  // giu nut 15 giay -> xoa het dien thoai
const uint32_t PAIR_WINDOW_MS = 60000;  // che do ghep doi mo trong 60 giay
const uint8_t  PAIR_MAX_TRIES = 3;      // go sai ma 3 lan -> huy ghep doi

// ---- RFID RC522 (SPI) + van tay AS608 (UART2) ----
#define RC522_SS   5
#define RC522_RST  4
#define RC522_SCK  18
#define RC522_MISO 19
#define RC522_MOSI 23
#define FP_RX      16  // ESP32 nhan <- TX cua AS608
#define FP_TX      17  // ESP32 gui  -> RX cua AS608

// ---- Bo nho ----
#define MAX_PHONES  8
#define MAX_CARDS   20
#define MAX_FINGERS 32   // ID van tay 1..32 trong AS608
#define LOG_CAPACITY 500 // so ban ghi nhat ky (vong tron, 16 byte/ban ghi)

// ---- Ma PIN ----
const uint8_t  PIN_MIN_LEN    = 4;
const uint8_t  PIN_MAX_LEN    = 8;
const uint8_t  PIN_MAX_WRONG  = 5;       // sai 5 lan lien tiep -> khoa ban phim
const uint32_t PIN_LOCKOUT_MS = 300000;  // khoa ban phim 5 phut
const uint32_t PIN_IDLE_MS    = 10000;   // 10 giay khong bam -> xoa so dang go

// ---- Dang ky the / van tay ----
const uint32_t ENROLL_CARD_MS   = 15000;
const uint32_t ENROLL_FINGER_MS = 15000;  // cho moi lan dat tay

// ---- Chu ky do cam bien ----
// Moi lan do chan loop() vai chuc ms (AS608 ~50ms, RC522 ~30ms). Neu ban phim bi sot phim thi tang 2 so nay.
const uint32_t FP_POLL_MS   = 300;
const uint32_t RFID_POLL_MS = 100;
const uint32_t SAME_CARD_MS = 2000;  // bo qua cung 1 the quet lien tuc

// ---- Phan hoi ----
// Goi notify toi da 244 byte (MTU 247): 2 dau + 12 IV + 6 (cmd, ket qua, bo dem) + payload + 16 tag
#define MAX_REPLY_PAYLOAD 208
#define LOGS_PER_REPLY    12   // 9 + 12 x 16 = 201 byte

// ---- Loai goi (byte dau) ----
#define FRAME_CHALLENGE_REQ 0x01
#define FRAME_SEALED_CMD    0x02
#define FRAME_PAIR_REQ      0x03  // [0x03][khoa cong khai X25519 cua dien thoai 32B]
#define FRAME_CHALLENGE     0x81
#define FRAME_SEALED_REPLY  0x82
#define FRAME_PAIR_RESP     0x83  // [0x83][khoa cong khai cua khoa 32B][keyId]
#define FRAME_PAIR_RESULT   0x84  // [0x84][ket qua][keyId]
#define FRAME_PAIR_ERROR    0x85  // [0x85][ma loi]
#define FRAME_PROGRESS      0x86  // [0x86][cmd][buoc] - khong ma hoa, chi de app hien huong dan khi dang ky van tay
                                  //   buoc 1 = da doc lan 1, nhac tay ra | buoc 2 = dat lai ngon tay lan 2

// Lenh (trong phan ma hoa)
#define CMD_UNLOCK        0x10
#define CMD_LOCK          0x11
#define CMD_STATUS        0x12  // -> [relay][uptime 4B][so lan mo 4B][so dien thoai][dang ghep doi][vai tro][ban phim bi khoa]
// Cac lenh tu 0x20 tro len chi danh cho admin
#define CMD_GET_LOGS      0x20  // [tu ban ghi so 4B] -> [tong 4B][ban ghi dau tien 4B][so ban ghi 1B][ban ghi 16B ...]
                                //   ban ghi chep nguyen struct LogRecord: thoi gian 4B LITTLE-endian (cac so khac trong giao thuc la big-endian)
#define CMD_ENROLL_CARD   0x30  // admin; cho quet the 15 giay -> [chi so][do dai UID][UID]
#define CMD_DELETE_CARD   0x31  // admin; [chi so] (0xFF = xoa het)
#define CMD_ENROLL_FINGER 0x32  // admin; dat tay 2 lan -> [ID van tay]
#define CMD_DELETE_FINGER 0x33  // admin; [ID] (0xFF = xoa het)
#define CMD_SET_PIN       0x34  // admin; [do dai][cac chu so ASCII] (do dai 0 = tat PIN)
#define CMD_LIST_ACCESS   0x36  // admin; -> [co PIN][mat na van tay 4B][so the][{chi so, do dai, UID}...]

// Ket qua lenh
#define RES_OK           0x00
#define RES_BAD_NONCE    0x01
#define RES_BAD_COUNTER  0x02
#define RES_DENIED       0x03  // khong du quyen (chi admin)
#define RES_BUSY         0x04
#define RES_UNKNOWN_CMD  0x05
#define RES_TIMEOUT      0x06  // het gio cho quet the / dat tay
#define RES_ENROLL_FAIL  0x07  // 2 lan dat tay khong khop / loi cam bien
#define RES_FULL         0x08  // het cho luu
#define RES_BAD_ARG      0x09  // tham so sai (PIN qua ngan / dai...)
#define RES_EXISTS       0x0A  // the / van tay da duoc dang ky
#define RES_NO_SENSOR    0x0B  // khong ket noi duoc RC522 / AS608

// ---- Nhat ky: phuong thuc mo va ket qua ----
#define LOG_APP    1
#define LOG_CARD   2
#define LOG_FINGER 3
#define LOG_PIN    4
#define LOG_BUTTON 5
#define LOG_OK          0
#define LOG_UNKNOWN     1  // the / van tay chua dang ky
#define LOG_WRONG_PIN   2
#define LOG_PIN_LOCKOUT 3  // sai PIN qua 5 lan -> khoa ban phim

// Ket qua / loi ghep doi
#define PAIR_OK          0x00
#define PAIR_BAD_CODE    0x01  // go sai ma qua 3 lan
#define PAIR_TIMEOUT     0x02  // het 60 giay chua go ma
#define PAIR_NOT_IN_MODE 0x10  // khoa chua o che do ghep doi (chua giu nut)
#define PAIR_FULL        0x11  // da du MAX_PHONES dien thoai
#define PAIR_BUSY        0x12  // dang ghep doi voi dien thoai khac
