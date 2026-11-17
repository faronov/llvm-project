# RUN: llvm-mc -triple=mcs51 -filetype=obj %s -o %t.o
# RUN: ld.lld -m elf32-mcs51 -T %S/../../../llvm/lib/Target/MCS51/cc2530.ld \
# RUN:   --no-check-sections --icf=safe -o %t.elf %t.o
# RUN: llvm-nm -n %t.elf | FileCheck %s

# Machine-outlined helpers are entered with a plain LCALL. A helper that only
# automatically banked functions call is placed in their bank; a helper that
# common code also calls stays in common flash.
.section .vectors,"ax"
.globl reset
reset:
  ljmp main

.section .text.main,"ax"
.globl main
.type main,@function
main:
  lcall OUTLINED_FUNCTION_1
  ret

.section .text.f1,"ax"
.globl f1
.type f1,@function
f1:
  lcall OUTLINED_FUNCTION_0
  ret

.section .text.f2,"ax"
.globl f2
.type f2,@function
f2:
  lcall OUTLINED_FUNCTION_0
  lcall OUTLINED_FUNCTION_1
  ret

.section .text.__mcs51_outlined.OUTLINED_FUNCTION_0,"ax"
.type OUTLINED_FUNCTION_0,@function
OUTLINED_FUNCTION_0:
  inc a
  ret

.section .text.__mcs51_outlined.OUTLINED_FUNCTION_1,"ax"
.type OUTLINED_FUNCTION_1,@function
OUTLINED_FUNCTION_1:
  inc a
  ret

# CHECK:      00000094 T main
# CHECK:      00000097 t OUTLINED_FUNCTION_1
# CHECK:      00008000 t OUTLINED_FUNCTION_0
# CHECK:      00008002 T f1
# CHECK-NEXT: 00008005 T f2
