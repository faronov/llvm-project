; RUN: llc -mtriple=mcs51 -mcpu=cc2530 -O2 -verify-machineinstrs %s -o - | FileCheck %s --check-prefix=CC2530
; RUN: llc -mtriple=mcs51 -O2 -verify-machineinstrs %s -o - | FileCheck %s --check-prefix=GENERIC

; A DATA or IDATA address widened to a near (XDATA) pointer. The CC2530 maps
; its internal RAM into XDATA at 0x1F00-0x1FFF, so the high byte is 0x1F: a
; callee that writes through the pointer with MOVX must reach the stack
; object, not XDATA page 0 (PDATA and the static frames). Generic MCS-51 has
; no such mirror and keeps the zero high byte.

@d = addrspace(1) global i8 1
@i = addrspace(2) global i8 2
@p = addrspace(3) global i8 3

declare void @fill(ptr)

define i8 @stack_object() {
; CC2530-LABEL: stack_object:
; CC2530:       mov [[HI:r[0-7]]], #31
; CC2530:       lcall fill
; GENERIC-LABEL: stack_object:
; GENERIC:       mov [[HI:r[0-7]]], #0
; GENERIC:       lcall fill
  %cap = alloca i8, align 1, addrspace(2)
  %near = addrspacecast ptr addrspace(2) %cap to ptr
  call void @fill(ptr %near)
  %v = load i8, ptr addrspace(2) %cap, align 1
  ret i8 %v
}

define ptr @data_object() {
; CC2530-LABEL: data_object:
; CC2530:       #31
; GENERIC-LABEL: data_object:
; GENERIC-NOT:  #31
; GENERIC:      ret
  %near = addrspacecast ptr addrspace(1) @d to ptr
  ret ptr %near
}

define ptr @idata_object() {
; CC2530-LABEL: idata_object:
; CC2530:       #31
; GENERIC-LABEL: idata_object:
; GENERIC-NOT:  #31
; GENERIC:      ret
  %near = addrspacecast ptr addrspace(2) @i to ptr
  ret ptr %near
}

; PDATA lies in XDATA page 0 on both.
define ptr @pdata_object() {
; CC2530-LABEL: pdata_object:
; CC2530-NOT:   #31
; CC2530:       ret
  %near = addrspacecast ptr addrspace(3) @p to ptr
  ret ptr %near
}
