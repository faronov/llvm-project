# RUN: llvm-mc -triple=tc32-unknown-none-elf -filetype=obj %s -o %t
# RUN: llvm-readobj --sections --section-data --symbols %t | FileCheck %s --check-prefixes=COMMON,TC32
# RUN: llvm-mc -triple=thumbv6m-unknown-none-eabi -filetype=obj %s -o %t.arm
# RUN: llvm-readobj --sections --section-data --symbols %t.arm | FileCheck %s --check-prefixes=COMMON,ARM

# TC32 rounds allocatable non-code sections up to their alignment. Padding
# must be emitted before MCAssembler checks the final section size.

# COMMON: Name: .data.padded
# COMMON: Type: SHT_PROGBITS
# TC32: Size: 16
# ARM: Size: 14
# COMMON: AddressAlignment: 4
# COMMON: SectionData (
# TC32-NEXT: 0000: 01020304 05060708 090A0B0C 0D0E0000
# ARM-NEXT: 0000: 01020304 05060708 090A0B0C 0D0E

# COMMON: Name: .rodata.padded
# TC32: Size: 8
# ARM: Size: 1
# COMMON: AddressAlignment: 8
# COMMON: SectionData (
# TC32-NEXT: 0000: 11000000 00000000
# ARM-NEXT: 0000: 11

# COMMON: Name: .bss.padded
# COMMON: Type: SHT_NOBITS
# TC32: Size: 4
# ARM: Size: 1
# COMMON: AddressAlignment: 4

# COMMON: Name: .note.unallocated
# COMMON: Size: 1
# COMMON: AddressAlignment: 4

# COMMON: Name: .text.unpadded
# COMMON: Size: 2
# COMMON: AddressAlignment: 4

# COMMON: Name: payload
# COMMON: Size: 14

.section .data.padded,"aw",%progbits
.p2align 2
.type payload,%object
payload:
.byte 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14
.size payload, .-payload

.section .rodata.padded,"a",%progbits
.p2align 3
.byte 17

.section .bss.padded,"aw",%nobits
.p2align 2
.zero 1

.section .note.unallocated,"",%progbits
.p2align 2
.byte 18

.section .text.unpadded,"ax",%progbits
.p2align 2
.short 0
