/* CRC-16/CCITT-FALSE, hand-written C reference for the Rust version in poc/crc16 */
#include <stdint.h>

uint16_t c_crc16(uint8_t *data, uint16_t len)
{
	uint16_t crc = 0xffff;
	uint16_t i;
	uint8_t b;

	for (i = 0; i < len; i++) {
		crc ^= (uint16_t)data[i] << 8;
		for (b = 0; b < 8; b++)
			crc = (crc & 0x8000) ? (crc << 1) ^ 0x1021 : crc << 1;
	}
	return crc;
}
