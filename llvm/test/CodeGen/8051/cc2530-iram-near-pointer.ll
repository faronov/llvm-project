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

; A run-time DATA/IDATA address may be null. The null pointer stays the
; all-zero near null, like the constant conversion; only non-null addresses
; get the mirror high byte.
define ptr @idata_dynamic(ptr addrspace(2) %p) {
; CC2530-LABEL: idata_dynamic:
; CC2530:       cjne r7, #0,
; CC2530:       #31
; GENERIC-LABEL: idata_dynamic:
; GENERIC-NOT:  #31
; GENERIC:      ret
  %near = addrspacecast ptr addrspace(2) %p to ptr
  ret ptr %near
}

define ptr @data_dynamic(ptr addrspace(1) %p) {
; CC2530-LABEL: data_dynamic:
; CC2530:       cjne r7, #0,
; CC2530:       #31
  %near = addrspacecast ptr addrspace(1) %p to ptr
  ret ptr %near
}

; A nonnull argument needs no null test.
define ptr @idata_nonnull(ptr addrspace(2) nonnull %p) {
; CC2530-LABEL: idata_nonnull:
; CC2530-NOT:   cjne
; CC2530:       #31
; CC2530:       ret
  %near = addrspacecast ptr addrspace(2) %p to ptr
  ret ptr %near
}

; Generic to near: a DATA/IDATA tag (0x40) names internal RAM, so the near
; pointer is its mirror, as for the direct conversion. Other tags keep the
; 16-bit address; the generic null has a zero tag and stays null.
define ptr @generic_to_near(ptr addrspace(8) %p) {
; CC2530-LABEL: generic_to_near:
; CC2530:       #31
; CC2530:       #64
; CC2530:       ret
; GENERIC-LABEL: generic_to_near:
; GENERIC-NOT:  #31
; GENERIC-NOT:  #64
; GENERIC:      ret
  %near = addrspacecast ptr addrspace(8) %p to ptr
  ret ptr %near
}

; An explicit XDATA conversion keeps the address value.
define ptr addrspace(4) @generic_to_xdata(ptr addrspace(8) %p) {
; CC2530-LABEL: generic_to_xdata:
; CC2530-NOT:   #31
; CC2530:       ret
  %x = addrspacecast ptr addrspace(8) %p to ptr addrspace(4)
  ret ptr addrspace(4) %x
}

; Dereferencing an IDATA global through a near pointer must use the mirrored
; address too, not the IDATA symbol as an XDATA address.
@local = external addrspace(2) global i8

define i8 @idata_load_near() {
; CC2530-LABEL: idata_load_near:
; CC2530-NOT:   xdata16(local)
; CC2530:       #31
; CC2530:       movx a, @dptr
  %v = load i8, ptr addrspacecast (ptr addrspace(2) @local to ptr), align 1
  ret i8 %v
}

define void @idata_store_near() {
; CC2530-LABEL: idata_store_near:
; CC2530-NOT:   xdata16(local)
; CC2530:       #31
; CC2530:       movx @dptr, a
  store i8 5, ptr addrspacecast (ptr addrspace(2) @local to ptr), align 1
  ret void
}
