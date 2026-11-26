; RUN: not llc -mtriple=mcs51 -mcpu=cc2530 -O2 %s -o /dev/null 2>&1 | FileCheck %s --check-prefix=ERR

; The generic access helpers move one byte at a time: a wider atomic access
; through a generic pointer would silently become interruptible byte
; accesses, so it is rejected.

; ERR: error: {{.*}}atomic_get16{{.*}}atomic access wider than one byte through an MCS-51 generic pointer
; ERR: error: {{.*}}atomic_put16{{.*}}atomic access wider than one byte through an MCS-51 generic pointer
; ERR-NOT: atomic_get8
; ERR-NOT: atomic_put8

define i16 @atomic_get16(ptr addrspace(8) %p) {
  %v = load atomic i16, ptr addrspace(8) %p seq_cst, align 2
  ret i16 %v
}

define void @atomic_put16(ptr addrspace(8) %p, i16 %v) {
  store atomic i16 %v, ptr addrspace(8) %p seq_cst, align 2
  ret void
}

define i8 @atomic_get8(ptr addrspace(8) %p) {
  %v = load atomic i8, ptr addrspace(8) %p seq_cst, align 1
  ret i8 %v
}

define void @atomic_put8(ptr addrspace(8) %p, i8 %v) {
  store atomic i8 %v, ptr addrspace(8) %p seq_cst, align 1
  ret void
}
