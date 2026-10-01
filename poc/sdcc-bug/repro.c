/*
 * SDCC 4.6.0 #16555, -mmcs51 (--model-large and --model-small): *(T*)&p[i] through a generic
 * pointer reads the wrong byte; p[i] is correct.
 * Build: sdcc -mmcs51 --model-large repro.c
 * Run:   s51 -t 8052 -S out=serial.txt -g repro.ihx   (expect "31 31"; prints "31 dc" large, "31 01" small)
 */
#include <stdint.h>
#include <8052.h>

__xdata uint8_t buf[] = "123";

uint8_t good(void *v, uint16_t i)
{
	return ((uint8_t *)v)[i];
}

uint8_t bad(void *v, uint16_t i)
{
	return *(uint8_t *)(&((uint8_t *)v)[i]);
}

static void hex8(uint8_t v)
{
	uint8_t n;
	n = v >> 4; SBUF = n < 10 ? '0' + n : 'a' + n - 10; while (!TI); TI = 0;
	n = v & 15; SBUF = n < 10 ? '0' + n : 'a' + n - 10; while (!TI); TI = 0;
	SBUF = ' '; while (!TI); TI = 0;
}

void main(void)
{
	SCON = 0x50; TMOD = 0x20; TH1 = 0xfd; TR1 = 1; TI = 0;
	hex8(good(buf, 0));
	hex8(bad(buf, 0));
	SBUF = '#'; while (!TI); TI = 0;
	while (1)
		;
}
