; RUN: llc -mtriple=mcs51 -mcpu=cc2530 -O2 -mcs51-rn-words -mcs51-csr=none -verify-machineinstrs %s -o - | FileCheck %s

; The hand-written 32-bit shift helpers keep their operands and result in
; IP0-IP1 (direct 48-51) under every ABI option. An explicit C call to the
; declared helper must use that convention like the shift libcall does.

declare i32 @__ashlsi3(i32, i16)

define i32 @explicit_call(i32 %x, i16 %n) {
; CHECK-LABEL: explicit_call:
; CHECK-DAG:   mov 48, r2
; CHECK-DAG:   mov 49, r3
; CHECK-DAG:   mov 50, r4
; CHECK-DAG:   mov 51, r5
; CHECK:       lcall {{.*}}__ashlsi3
; CHECK-DAG:   mov r2, 48
; CHECK-DAG:   mov r3, 49
; CHECK-DAG:   mov r4, 50
; CHECK-DAG:   mov r5, 51
; CHECK:       ret
  %r = call i32 @__ashlsi3(i32 %x, i16 %n)
  ret i32 %r
}
