# RUN: llvm-mc -triple=mcs51 -filetype=obj %s -o %t.o
# RUN: echo 'SECTIONS { .bank1 0x8000 : AT(0x8000) { *(.bank1.*) } \
# RUN:   .bank2 0x8000 : AT(0x10000) { *(.bank2.*) } }' > %t.ld
# RUN: not ld.lld -m elf32-mcs51 -T %t.ld --no-check-sections -o %t.elf %t.o 2>&1 | FileCheck %s

# A direct transfer to a local label (a section-symbol relocation, not an
# STT_FUNC symbol) gets no bank-call trampoline, so it cannot cross banks.
# Within the caller's bank it is accepted.

.section .bank1.text,"ax",@progbits
.globl _start
_start:
  acall .Lsame
  acall .Lother
  lcall .Lother
  ljmp .Lother
.Lsame:
  ret

.section .bank2.text,"ax",@progbits
.Lother:
  mov a, #42
  ret

# CHECK-NOT: .bank1.text+0x0)
# CHECK: (.bank1.text+0x2)MCS-51 direct jump/call cannot cross from bank 1 to bank 2 for '<section symbol>'
# CHECK: (.bank1.text+0x5)MCS-51 direct jump/call cannot cross from bank 1 to bank 2 for '<section symbol>'
# CHECK: (.bank1.text+0x8)MCS-51 direct jump/call cannot cross from bank 1 to bank 2 for '<section symbol>'
