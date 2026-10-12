// Ma hoa cho khoa: AES-256-GCM (lenh), X25519 + HKDF-SHA256 (ghep doi).
// Phai cho ket qua giong het lib/core/crypto/lock_crypto.dart (goi cryptography cua Dart).
#pragma once
#include <Arduino.h>
#include "mbedtls/gcm.h"
#include "mbedtls/ecdh.h"
#include "mbedtls/hkdf.h"
#include "mbedtls/md.h"
#include "esp_random.h"

static int rngFill(void *, unsigned char *buf, size_t len) {
  esp_fill_random(buf, len);
  return 0;
}

// ---------------- AES-256-GCM, IV 12 byte, tag 16 byte, AAD = 1 byte keyId ----------------
static bool gcmSeal(const uint8_t key[32], uint8_t keyId, const uint8_t *plain, size_t len,
                    uint8_t iv[12], uint8_t *cipher, uint8_t tag[16]) {
  esp_fill_random(iv, 12);
  mbedtls_gcm_context g;
  mbedtls_gcm_init(&g);
  bool ok = mbedtls_gcm_setkey(&g, MBEDTLS_CIPHER_ID_AES, key, 256) == 0 &&
            mbedtls_gcm_crypt_and_tag(&g, MBEDTLS_GCM_ENCRYPT, len, iv, 12, &keyId, 1, plain, cipher, 16, tag) == 0;
  mbedtls_gcm_free(&g);
  return ok;
}

static bool gcmOpen(const uint8_t key[32], uint8_t keyId, const uint8_t iv[12], const uint8_t *cipher,
                    size_t len, const uint8_t tag[16], uint8_t *plain) {
  mbedtls_gcm_context g;
  mbedtls_gcm_init(&g);
  bool ok = mbedtls_gcm_setkey(&g, MBEDTLS_CIPHER_ID_AES, key, 256) == 0 &&
            mbedtls_gcm_auth_decrypt(&g, len, iv, 12, &keyId, 1, tag, 16, cipher, plain) == 0;
  mbedtls_gcm_free(&g);
  return ok;
}

// ---------------- X25519 (RFC 7748, khoa 32 byte little-endian) ----------------
static bool x25519Keypair(uint8_t priv[32], uint8_t pub[32]) {
  mbedtls_ecp_group grp;
  mbedtls_mpi d;
  mbedtls_ecp_point q;
  mbedtls_ecp_group_init(&grp);
  mbedtls_mpi_init(&d);
  mbedtls_ecp_point_init(&q);
  size_t olen = 0;
  bool ok = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_CURVE25519) == 0 &&
            mbedtls_ecdh_gen_public(&grp, &d, &q, rngFill, nullptr) == 0 &&
            mbedtls_mpi_write_binary_le(&d, priv, 32) == 0 &&
            mbedtls_ecp_point_write_binary(&grp, &q, MBEDTLS_ECP_PF_UNCOMPRESSED, &olen, pub, 32) == 0 &&
            olen == 32;
  mbedtls_ecp_point_free(&q);
  mbedtls_mpi_free(&d);
  mbedtls_ecp_group_free(&grp);
  return ok;
}

static bool x25519Shared(const uint8_t priv[32], const uint8_t peerPub[32], uint8_t shared[32]) {
  mbedtls_ecp_group grp;
  mbedtls_mpi d, z;
  mbedtls_ecp_point qp;
  mbedtls_ecp_group_init(&grp);
  mbedtls_mpi_init(&d);
  mbedtls_mpi_init(&z);
  mbedtls_ecp_point_init(&qp);
  bool ok = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_CURVE25519) == 0 &&
            mbedtls_mpi_read_binary_le(&d, priv, 32) == 0 &&
            mbedtls_ecp_point_read_binary(&grp, &qp, peerPub, 32) == 0 &&
            mbedtls_ecdh_compute_shared(&grp, &z, &qp, &d, rngFill, nullptr) == 0 &&
            mbedtls_mpi_write_binary_le(&z, shared, 32) == 0;
  mbedtls_ecp_point_free(&qp);
  mbedtls_mpi_free(&z);
  mbedtls_mpi_free(&d);
  mbedtls_ecp_group_free(&grp);
  return ok;
}

// ---------------- HKDF-SHA256, salt "khoabaomat-v1" ----------------
static bool hkdf32(const uint8_t ikm[32], const uint8_t *info, size_t infoLen, uint8_t out[32]) {
  static const uint8_t SALT[] = {'k','h','o','a','b','a','o','m','a','t','-','v','1'};
  return mbedtls_hkdf(mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), SALT, sizeof(SALT), ikm, 32,
                      info, infoLen, out, 32) == 0;
}

// Khoa AES rieng cua dien thoai = HKDF(shared, info=[keyId]); ma 6 so = HKDF(shared, "confirm")
static bool derivePairing(const uint8_t shared[32], uint8_t keyId, uint8_t phoneKey[32], uint32_t *code) {
  static const uint8_t CONFIRM[] = {'c','o','n','f','i','r','m'};
  uint8_t c[32];
  if (!hkdf32(shared, &keyId, 1, phoneKey) || !hkdf32(shared, CONFIRM, sizeof(CONFIRM), c)) return false;
  uint32_t n = (((uint32_t)c[0] << 24) | ((uint32_t)c[1] << 16) | ((uint32_t)c[2] << 8) | c[3]) & 0x7fffffff;
  *code = n % 1000000;
  return true;
}
