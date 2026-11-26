; RUN: llc -mtriple=mcs51 -mcpu=cc2530 -O2 -verify-machineinstrs %s -o - | FileCheck %s

; An interrupt handler that writes ACC, B or PSW through their SFR byte or
; bit addresses must restore them. Selected direct addresses are
; sign-extended (ACC 0xe0 is -32); bit addresses 0x80-0xff name bits of the
; SFR at (address & 0xf8). Only PSW.RS0/RS1 switch the register bank.

define void @acc_byte() "interrupt"="0" {
; CHECK-LABEL: acc_byte:
; CHECK:       push 224
; CHECK:       mov -32, #1
; CHECK:       pop 224
; CHECK-NEXT:  reti
  store volatile i8 1, ptr addrspace(7) inttoptr (i8 -32 to ptr addrspace(7)), align 1
  ret void
}

define void @carry_bit() "interrupt"="1" {
; CHECK-LABEL: carry_bit:
; CHECK:       push 208
; CHECK-NEXT:  setb -41
; CHECK-NEXT:  pop 208
; CHECK-NEXT:  reti
  store volatile i8 1, ptr addrspace(6) inttoptr (i8 -41 to ptr addrspace(6)), align 1
  ret void
}

define void @psw_byte() "interrupt"="2" {
; CHECK-LABEL: psw_byte:
; CHECK:       push 208
; CHECK:       push 7
; CHECK:       mov -48, #0
; CHECK:       pop 208
; CHECK-NEXT:  reti
  store volatile i8 0, ptr addrspace(7) inttoptr (i8 -48 to ptr addrspace(7)), align 1
  ret void
}

define void @acc_bit() "interrupt"="3" {
; CHECK-LABEL: acc_bit:
; CHECK:       push 224
; CHECK-NEXT:  setb -32
; CHECK-NEXT:  pop 224
  store volatile i8 1, ptr addrspace(6) inttoptr (i8 -32 to ptr addrspace(6)), align 1
  ret void
}

define void @b_bit() "interrupt"="4" {
; CHECK-LABEL: b_bit:
; CHECK:       push 240
; CHECK-NEXT:  setb -16
; CHECK-NEXT:  pop 240
  store volatile i8 1, ptr addrspace(6) inttoptr (i8 -16 to ptr addrspace(6)), align 1
  ret void
}

define void @bank_bit() "interrupt"="5" {
; CHECK-LABEL: bank_bit:
; CHECK:       push 208
; CHECK-NEXT:  push 0
; CHECK:       push 7
; CHECK-NEXT:  setb -45
  store volatile i8 1, ptr addrspace(6) inttoptr (i8 -45 to ptr addrspace(6)), align 1
  ret void
}

; A port bit is not an architectural register: nothing to save.
define void @port_bit() "interrupt"="6" {
; CHECK-LABEL: port_bit:
; CHECK-NOT:   push
; CHECK:       setb -128
; CHECK-NEXT:  reti
  store volatile i8 1, ptr addrspace(6) inttoptr (i8 -128 to ptr addrspace(6)), align 1
  ret void
}
