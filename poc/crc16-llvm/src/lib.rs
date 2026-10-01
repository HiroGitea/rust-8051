//! CRC-16/CCITT-FALSE (poly 0x1021, init 0xffff), bitwise, for the rust-8051 PoC.
//! Same algorithm as poc/c/crc16.c, so the two can be compared on s51.
#![no_std]
// rustc_codegen_clr only keeps functions with explicit external linkage;
// #[no_mangle] alone is removed by its dead code elimination.
#![feature(linkage)]

#[no_mangle]
#[linkage = "external"]
pub extern "C" fn rs_crc16(data: *const u8, len: u16) -> u16 {
    let mut crc: u16 = 0xffff;
    let mut i: u16 = 0;
    while i < len {
        crc ^= (unsafe { *data.add(i as usize) } as u16) << 8;
        let mut b: u8 = 0;
        while b < 8 {
            crc = if crc & 0x8000 != 0 { (crc << 1) ^ 0x1021 } else { crc << 1 };
            b += 1;
        }
        i += 1;
    }
    crc
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}
