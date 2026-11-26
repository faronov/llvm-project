; RUN: llc -mtriple=mcs51 -mcpu=cc2530 -O2 -verify-machineinstrs %s -o - | FileCheck %s

; Releasing a frame larger than five bytes goes through A (mov a,sp; add;
; mov sp,a). A byte result returned in A must survive it: A is parked in a
; free R register across the SP update.

declare void @use(ptr addrspace(2))
declare i8 @get()

define i8 @constant_return() {
; CHECK-LABEL: constant_return:
; CHECK:       lcall {{.*}}use
; CHECK:       mov a, #42
; CHECK-NEXT:  mov [[R:r[0-7]]], a
; CHECK-NEXT:  mov a, 129
; CHECK-NEXT:  add a, #248
; CHECK-NEXT:  mov 129, a
; CHECK-NEXT:  mov a, [[R]]
; CHECK:       ret
  %a = alloca [8 x i8], align 1, addrspace(2)
  call void @use(ptr addrspace(2) %a)
  ret i8 42
}

define i8 @computed_return() {
; CHECK-LABEL: computed_return:
; CHECK:       lcall {{.*}}get
; CHECK:       mov [[R:r[0-7]]], a
; CHECK-NEXT:  mov a, 129
; CHECK-NEXT:  add a, #250
; CHECK-NEXT:  mov 129, a
; CHECK:       mov a, [[R]]
; CHECK-NEXT:  ret
  %a = alloca [6 x i8], align 1, addrspace(2)
  call void @use(ptr addrspace(2) %a)
  %p = getelementptr i8, ptr addrspace(2) %a, i8 3
  %v = load i8, ptr addrspace(2) %p, align 1
  %w = call i8 @get()
  %s = add i8 %v, %w
  ret i8 %s
}

; Five bytes and fewer use DEC SP, which leaves A alone.
define i8 @small_frame() {
; CHECK-LABEL: small_frame:
; CHECK:       mov a, #7
; CHECK-NEXT:  dec 129
; CHECK-NEXT:  dec 129
; CHECK-NEXT:  dec 129
; CHECK-NEXT:  dec 129
; CHECK-NEXT:  dec 129
; CHECK-NOT:   mov a, 129
; CHECK:       ret
  %a = alloca [5 x i8], align 1, addrspace(2)
  call void @use(ptr addrspace(2) %a)
  ret i8 7
}

; Without a byte result, A is free and nothing is parked.
define void @no_result() {
; CHECK-LABEL: no_result:
; CHECK:       lcall
; CHECK-NEXT:  mov a, 129
; CHECK-NEXT:  add a, #248
; CHECK-NEXT:  mov 129, a
; CHECK-NEXT:  pop
  %a = alloca [8 x i8], align 1, addrspace(2)
  call void @use(ptr addrspace(2) %a)
  ret void
}
