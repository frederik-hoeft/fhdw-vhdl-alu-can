#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>

// calculates a 15 bit CRC of the data in the buffer
uint16_t crc15(uint8_t* buffer_start, uint8_t* buffer_end) {
    uint16_t crc = 0x7fff;
    uint8_t* buffer = buffer_start;
    while (buffer < buffer_end) {
        crc ^= *buffer++ << 7;
        for (int i = 0; i < 8; i++) {
            crc <<= 1;
            if (crc & 0x8000) {
                crc ^= 0x4599;
            }
        }
    }
    return crc;
}

int main() {
    uint8_t buffer[] = {0x41, 0x41, 0x41, 0x41};
    uint16_t crc = crc15(buffer, buffer + sizeof(buffer));
    printf("crc: %#06x\n", crc);
    return 0;
}
