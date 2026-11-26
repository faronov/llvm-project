; RUN: llc -mtriple=mcs51 -mcpu=cc2530 -stop-before=mcs51-isel %s -o - | FileCheck %s --check-prefixes=CHECK,CC2530
; RUN: llc -mtriple=mcs51 -stop-before=mcs51-isel %s -o - | FileCheck %s --check-prefixes=CHECK,PLAIN

; memmove direction is chosen on physical memory, not address-space names.
; PDATA is XDATA page 0; on CC2530 internal RAM is mirrored into XDATA at
; 0x1F00. CODE never overlaps writable memory.

; CHECK-LABEL: define void @pdata_to_xdata(
; CHECK:       %[[S:.*]] = zext i8 %{{.*}} to i16
; CHECK:       %mcs51.memmove.distance = sub i16 %{{.*}}, %[[S]]
; CHECK:       %mcs51.memmove.overlap = and i1
; CHECK:       br i1 %mcs51.memmove.overlap
define void @pdata_to_xdata(ptr %dst, ptr addrspace(3) %src, i16 %n) {
  call void @llvm.memmove.p0.p3.i16(ptr %dst, ptr addrspace(3) %src, i16 %n, i1 false)
  ret void
}

; CHECK-LABEL: define void @idata_to_xdata(
; CC2530:      %[[M:.*]] = or disjoint i16 %{{.*}}, 7936
; CC2530:      %mcs51.memmove.distance = sub i16 %{{.*}}, %[[M]]
; CC2530:      br i1 %mcs51.memmove.overlap
; PLAIN:       mcs51.memmove.direction:
; PLAIN-NEXT:  br label %mcs51.memmove.forward
define void @idata_to_xdata(ptr %dst, ptr addrspace(2) %src, i16 %n) {
  call void @llvm.memmove.p0.p2.i16(ptr %dst, ptr addrspace(2) %src, i16 %n, i1 false)
  ret void
}

; CHECK-LABEL: define void @code_to_xdata(
; CHECK:       mcs51.memmove.direction:
; CHECK-NEXT:  br label %mcs51.memmove.forward
define void @code_to_xdata(ptr %dst, ptr addrspace(5) %src, i16 %n) {
  call void @llvm.memmove.p0.p5.i16(ptr %dst, ptr addrspace(5) %src, i16 %n, i1 false)
  ret void
}

; A generic IDATA (tag 0x40) or PDATA (tag 0x60) source shares XDATA-visible
; memory with a near destination on CC2530; tag 0x80 (CODE) never does.
; CHECK-LABEL: define void @generic_to_xdata(
; CHECK:       %mcs51.memmove.tag = trunc
; CHECK:       %mcs51.memmove.code = icmp {{eq|ne}} i8 %mcs51.memmove.tag, -128
; CC2530:      %mcs51.memmove.physical = select i1 %mcs51.memmove.iram
; CHECK:       %mcs51.memmove.same.space
define void @generic_to_xdata(ptr %dst, ptr addrspace(8) %src, i16 %n) {
  call void @llvm.memmove.p0.p8.i16(ptr %dst, ptr addrspace(8) %src, i16 %n, i1 false)
  ret void
}
