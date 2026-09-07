; RUN: opt -passes='cgscc(inline),function(sroa,instcombine)' -S %s | FileCheck %s
; RUN: opt -mtriple=tc32-unknown-none-elf -passes='default<O0>' -verify-each -S %s | opt -passes='cgscc(inline),function(sroa,instcombine)' -S | FileCheck %s

target triple = "tc32-unknown-none-elf"

define i8 @snapshot(ptr %p, i8 %replacement) {
entry:
  %before = load i16, ptr %p, align 1
  store volatile i8 %replacement, ptr %p, align 1
  %low = trunc i16 %before to i8
  ret i8 %low
}

define i32 @main() {
; CHECK-LABEL: define i32 @main(
; CHECK: ret i32 0
entry:
  %storage = alloca [2 x i8], align 2
  store i16 4660, ptr %storage, align 2
  %before = call i8 @snapshot(ptr %storage, i8 7)
  %wrong = icmp ne i8 %before, 52
  %status = zext i1 %wrong to i32
  ret i32 %status
}
