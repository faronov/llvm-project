# RUN: llvm-mc -triple=mcs51 -filetype=obj %s -o %t.o
# RUN: llvm-readobj --relocations %t.o | FileCheck %s --check-prefix=RELOC
# RUN: llvm-objdump -d %t.o | FileCheck %s --check-prefix=DIS

# Bytes of a symbol's address are loaded into the imaginary registers
# (direct addresses 48-71) with lo8/hi8 and resolved by the linker.
        .text
        mov     48, #lo8(sym+14)
        mov     49, #hi8(sym+14)
        mov     71, #lo8(other)
# Bank-0 R0-R7 take the two-byte Rn form.
        mov     r2, #lo8(sym+1)
        mov     r3, #hi8(sym+1)
        mov     r4, #xlo8(other)
        mov     r5, #xhi8(other)
        mov     r0, #clo8(sym)
        mov     r7, #chi8(sym)

# RELOC:      R_8051_LO8 sym 0xE
# RELOC-NEXT: R_8051_HI8 sym 0xE
# RELOC-NEXT: R_8051_LO8 other 0x0
# RELOC-NEXT: 0xA R_8051_LO8 sym 0x1
# RELOC-NEXT: 0xC R_8051_HI8 sym 0x1
# RELOC-NEXT: 0xE R_8051_LO8_XDATA other 0x0
# RELOC-NEXT: 0x10 R_8051_HI8_XDATA other 0x0
# RELOC-NEXT: 0x12 R_8051_LO8_CODE sym 0x0
# RELOC-NEXT: 0x14 R_8051_HI8_CODE sym 0x0
# DIS: 75 30 00 mov 48, #0
# DIS: 75 31 00 mov 49, #0
# DIS: 75 47 00 mov 71, #0
# DIS: 7a 00 mov r2, #0
# DIS: 7b 00 mov r3, #0
# DIS: 7c 00 mov r4, #0
# DIS: 7d 00 mov r5, #0
# DIS: 78 00 mov r0, #0
# DIS: 7f 00 mov r7, #0
