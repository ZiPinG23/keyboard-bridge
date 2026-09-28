#pragma once
#include <stdint.h>
#include <stddef.h>
namespace bridge {
inline uint32_t read32(const uint8_t* p) { return uint32_t(p[0]) | uint32_t(p[1])<<8 | uint32_t(p[2])<<16 | uint32_t(p[3])<<24; }
inline bool validFrame(const uint8_t* p, size_t size, bool established, uint32_t session, uint32_t sequence) {
    if (size != 20 || p[0] != 1 || p[1] != 1 || p[10] > 1 || p[18] || p[19]) return false;
    if (!p[10]) for (int i=11; i<18; ++i) if (p[i]) return false;
    const uint32_t sid = read32(p+2), seq = read32(p+6);
    if (!established) return !p[10] && sid != 0 && seq == 1;
    return sid == session && seq > sequence;
}
}
