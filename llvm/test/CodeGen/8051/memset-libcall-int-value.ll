; The runtime memset has the C prototype
;   void *memset(void *Destination, int Value, size_t Count);
; with a 16-bit int, so it reads Destination from IP0 (48:49), Value from IP1
; (50:51) and Count from IP2 (52:53), exactly what a direct C call passes.
; A memset intrinsic lowered to that libcall must pass the fill byte as a
; zero-extended int in IP1 and the length in IP2. Passing the i8 fill value in
; R7 and the length in IP1 made the runtime use the length as the fill value
; and a stale IP2 as the length.
; RUN: llc -mtriple=mcs51 -verify-machineinstrs < %s | FileCheck %s
; RUN: llc -mtriple=mcs51 -O0 -verify-machineinstrs < %s | FileCheck %s
; RUN: llc -mtriple=mcs51 -mcs51-csr=none -mcs51-wide-args \
; RUN:   -verify-machineinstrs < %s | FileCheck %s
; RUN: llc -mtriple=mcs51 -mcs51-csr=none -mcs51-wide-args \
; RUN:   -mcs51-static-frames -verify-machineinstrs < %s | FileCheck %s

@XBuffer = addrspace(4) global [64 x i8] zeroinitializer
@Buffer = global [64 x i8] zeroinitializer
@Fill = global i8 0
@Wide = global i16 0
@Count = global i16 0

declare void @llvm.memset.p0.i16(ptr, i8, i16, i1)
declare void @llvm.memset.p4.i16(ptr addrspace(4), i8, i16, i1)
declare ptr @memset(ptr, i16, i16)

; Reference: a direct C call as clang emits it for MCS-51, which is
; freestanding by default (nobuiltin). Value is the full 16-bit int.
; CHECK-LABEL: call_memset_prototype:
; CHECK: movx a, @dptr
; CHECK-NEXT: mov 50, a
; CHECK-NEXT: inc dptr
; CHECK-NEXT: movx a, @dptr
; CHECK-NEXT: mov 51, a
; CHECK-DAG: mov 52, a
; CHECK-DAG: mov 53, a
; CHECK-DAG: mov 48, #xlo8(Buffer)
; CHECK-DAG: mov 49, #xhi8(Buffer)
; CHECK: lcall memset
define void @call_memset_prototype() {
  %v = load volatile i16, ptr @Wide
  %n = load volatile i16, ptr @Count
  %r = call ptr @memset(ptr @Buffer, i16 %v, i16 %n) #0
  ret void
}

; Without nobuiltin, InstCombine in the MCS-51 IR pipeline turns the call
; into llvm.memset with a truncated i8 value; the libcall must still receive
; the fill byte as an int in IP1.
; CHECK-LABEL: call_memset_builtin:
; CHECK-DAG: mov 50, a
; CHECK-DAG: mov 51, {{#0|a}}
; CHECK-DAG: mov 52, a
; CHECK-DAG: mov 53, a
; CHECK-DAG: mov 48, #xlo8(Buffer)
; CHECK-DAG: mov 49, #xhi8(Buffer)
; CHECK-NOT: r7
; CHECK: lcall memset
define void @call_memset_builtin() {
  %v = load volatile i16, ptr @Wide
  %n = load volatile i16, ptr @Count
  %r = call ptr @memset(ptr @Buffer, i16 %v, i16 %n)
  ret void
}

; CHECK-LABEL: set_default_variable:
; CHECK: movx a, @dptr
; CHECK-NEXT: mov [[V:r[0-7]]], a
; CHECK-DAG: mov 52, a
; CHECK-DAG: mov 53, a
; CHECK-DAG: mov 48, #xlo8(Buffer)
; CHECK-DAG: mov 49, #xhi8(Buffer)
; CHECK-DAG: mov 50, [[V]]
; CHECK-DAG: mov 51, #0
; CHECK: lcall memset
define void @set_default_variable() {
  %v = load volatile i8, ptr @Fill
  %n = load volatile i16, ptr @Count
  call void @llvm.memset.p0.i16(ptr @Buffer, i8 %v, i16 %n, i1 false)
  ret void
}

; CHECK-LABEL: set_xdata_variable:
; CHECK: movx a, @dptr
; CHECK-NEXT: mov [[V:r[0-7]]], a
; CHECK-DAG: mov 52, a
; CHECK-DAG: mov 53, a
; CHECK-DAG: mov 48, #xlo8(XBuffer)
; CHECK-DAG: mov 49, #xhi8(XBuffer)
; CHECK-DAG: mov 50, [[V]]
; CHECK-DAG: mov 51, #0
; CHECK: lcall memset
define void @set_xdata_variable() {
  %v = load volatile i8, ptr @Fill
  %n = load volatile i16, ptr @Count
  call void @llvm.memset.p4.i16(ptr addrspace(4) @XBuffer, i8 %v, i16 %n, i1 false)
  ret void
}

; A constant length above the inline-store limit still uses the libcall.
; CHECK-LABEL: set_xdata_constant_length:
; CHECK-DAG: mov 50, r7
; CHECK-DAG: mov 51, a
; CHECK-DAG: mov 48, #xlo8(XBuffer)
; CHECK-DAG: mov 49, #xhi8(XBuffer)
; CHECK-DAG: mov 52, #64
; CHECK-DAG: mov 53, a
; CHECK: lcall memset
define void @set_xdata_constant_length(i8 %v) {
  call void @llvm.memset.p4.i16(ptr addrspace(4) @XBuffer, i8 %v, i16 64, i1 false)
  ret void
}

; Incoming Destination/Count/Value arrive in IP0/IP1/R7: Count must be moved
; to IP2 before IP1 is overwritten with the fill value.
; CHECK-LABEL: set_arguments:
; CHECK: mov 52, 50
; CHECK-NEXT: mov 53, 51
; CHECK-NEXT: mov 50, r7
; CHECK-NEXT: mov 51, #0
; CHECK-NEXT: lcall memset
define void @set_arguments(ptr %d, i8 %v, i16 %n) {
  call void @llvm.memset.p0.i16(ptr %d, i8 %v, i16 %n, i1 false)
  ret void
}

attributes #0 = { nobuiltin }
