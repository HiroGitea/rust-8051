/*
 * s51 test harness: runs the three CRC16 versions (hand-written C, Rust via
 * rustc_codegen_clr, Rust via llvm-cbe) on 9 and 256 bytes and prints the
 * results and the machine cycles of each call (hex) on the serial port
 */
#include <stdint.h>
#include <8052.h>

uint16_t c_crc16(uint8_t *data, uint16_t len);
uint16_t rs_crc16(uint8_t *data, uint16_t len);
uint16_t cbe_crc16(void *data, uint16_t len);

__xdata uint8_t msg[] = "123456789";
__xdata uint8_t big[256];

int putchar(int c)
{
	SBUF = c;
	while (!TI)
		;
	TI = 0;
	return c;
}

static void hex16(uint16_t v)
{
	uint8_t i;
	for (i = 0; i < 4; i++) {
		uint8_t n = (v >> 12) & 0xf;
		putchar(n < 10 ? '0' + n : 'a' + n - 10);
		v <<= 4;
	}
	putchar(' ');
}

__xdata uint16_t res[6];

/* Timer 0 counts machine cycles, its overflows are counted in t0_ovf */
__xdata uint16_t t0_ovf;
__xdata uint32_t cycles[6];

void t0_isr(void) __interrupt(1)
{
	t0_ovf++;
}

static void t_start(void)
{
	TR0 = 0; TH0 = 0; TL0 = 0; t0_ovf = 0; TF0 = 0; TR0 = 1;
}

static uint32_t t_stop(void)
{
	TR0 = 0;
	return ((uint32_t)t0_ovf << 16) | ((uint16_t)TH0 << 8) | TL0;
}

void main(void)
{
	uint16_t i;

	SCON = 0x50; TH1 = 0xfd; TR1 = 1; TI = 0;
	for (i = 0; i < sizeof(big); i++)
		big[i] = i * 7;
	TMOD = 0x21; ET0 = 1; EA = 1;
	t_start(); res[0] = c_crc16(msg, 9); cycles[0] = t_stop();
	t_start(); res[1] = rs_crc16(msg, 9); cycles[1] = t_stop();
	t_start(); res[2] = c_crc16(big, sizeof(big)); cycles[2] = t_stop();
	t_start(); res[3] = rs_crc16(big, sizeof(big)); cycles[3] = t_stop();
	t_start(); res[4] = cbe_crc16(msg, 9); cycles[4] = t_stop();
	t_start(); res[5] = cbe_crc16(big, sizeof(big)); cycles[5] = t_stop();
	EA = 0;
	/* Results, then cycles: c 9, clr 9, c 256, clr 256, cbe 9, cbe 256 */
	for (i = 0; i < 6; i++)
		hex16(res[i]);
	putchar('\n');
	for (i = 0; i < 6; i++) {
		hex16(cycles[i] >> 16);
		hex16(cycles[i]);
	}
	putchar('\n');
	putchar('#');
	while (1)
		;
}
