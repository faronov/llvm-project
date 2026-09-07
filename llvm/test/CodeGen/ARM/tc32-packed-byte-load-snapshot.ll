; RUN: opt -mtriple=tc32-unknown-none-elf -passes='default<O0>' -verify-each -S %s | FileCheck %s
; RUN: opt -mtriple=thumbv6m-unknown-none-eabi -passes='default<O0>' -verify-each -S %s | FileCheck %s --check-prefix=ARM

target triple = "tc32-unknown-none-elf"

declare void @clobber(ptr)
declare void @consume(i8)

define i8 @low_byte_before_store(ptr %p, i8 %replacement) {
; CHECK-LABEL: define i8 @low_byte_before_store(
; CHECK: entry:
; CHECK-NEXT: [[LOW:%.*]] = load i8, ptr %p, align 1
; CHECK-NEXT: store volatile i8 %replacement, ptr %p, align 1
; CHECK-NEXT: ret i8 [[LOW]]
; ARM-LABEL: define i8 @low_byte_before_store(
; ARM: %before = load i16, ptr %p, align 1
; ARM-NEXT: store volatile i8 %replacement, ptr %p, align 1
; ARM-NEXT: %low = trunc i16 %before to i8
; ARM-NEXT: ret i8 %low
entry:
  %before = load i16, ptr %p, align 1
  store volatile i8 %replacement, ptr %p, align 1
  %low = trunc i16 %before to i8
  ret i8 %low
}

define i8 @high_byte_before_store(ptr %p, i8 %replacement) {
; CHECK-LABEL: define i8 @high_byte_before_store(
; CHECK: entry:
; CHECK-NEXT: [[PTR:%.*]] = getelementptr i8, ptr %p, i32 2
; CHECK-NEXT: [[HIGH:%.*]] = load i8, ptr [[PTR]], align 1
; CHECK-NEXT: %dst = getelementptr i8, ptr %p, i32 2
; CHECK-NEXT: store i8 %replacement, ptr %dst, align 1
; CHECK-NEXT: ret i8 [[HIGH]]
entry:
  %before = load i32, ptr %p, align 1
  %dst = getelementptr i8, ptr %p, i32 2
  store i8 %replacement, ptr %dst, align 1
  %shift = lshr i32 %before, 16
  %high = trunc i32 %shift to i8
  ret i8 %high
}

define i8 @byte_before_call(ptr %p) {
; CHECK-LABEL: define i8 @byte_before_call(
; CHECK: entry:
; CHECK-NEXT: [[PTR:%.*]] = getelementptr i8, ptr %p, i32 3
; CHECK-NEXT: [[HIGH:%.*]] = load i8, ptr [[PTR]], align 1
; CHECK-NEXT: call void @clobber(ptr %p)
; CHECK-NEXT: ret i8 [[HIGH]]
entry:
  %before = load i32, ptr %p, align 1
  call void @clobber(ptr %p)
  %shift = lshr i32 %before, 24
  %high = trunc i32 %shift to i8
  ret i8 %high
}

define i8 @repeated_low_byte(ptr %p, i8 %replacement) {
; CHECK-LABEL: define i8 @repeated_low_byte(
; CHECK: entry:
; CHECK-NEXT: [[LOW:%.*]] = load i8, ptr %p, align 1
; CHECK-NEXT: store volatile i8 %replacement, ptr %p, align 1
; CHECK-NEXT: %sum = add i8 [[LOW]], [[LOW]]
; CHECK-NEXT: ret i8 %sum
entry:
  %before = load i32, ptr %p, align 1
  %first = trunc i32 %before to i8
  store volatile i8 %replacement, ptr %p, align 1
  %second = trunc i32 %before to i8
  %sum = add i8 %first, %second
  ret i8 %sum
}

define i8 @repeated_high_byte(ptr %p) {
; CHECK-LABEL: define i8 @repeated_high_byte(
; CHECK: entry:
; CHECK-NEXT: [[PTR:%.*]] = getelementptr i8, ptr %p, i32 1
; CHECK-NEXT: [[HIGH:%.*]] = load i8, ptr [[PTR]], align 1
; CHECK-NEXT: call void @clobber(ptr %p)
; CHECK-NEXT: %sum = add i8 [[HIGH]], [[HIGH]]
; CHECK-NEXT: ret i8 %sum
entry:
  %before = load i16, ptr %p, align 1
  %shift1 = lshr i16 %before, 8
  %first = trunc i16 %shift1 to i8
  call void @clobber(ptr %p)
  %shift2 = lshr i16 %before, 8
  %second = trunc i16 %shift2 to i8
  %sum = add i8 %first, %second
  ret i8 %sum
}

define i8 @two_bytes_before_call(ptr %p) {
; CHECK-LABEL: define i8 @two_bytes_before_call(
; CHECK: entry:
; CHECK-DAG: [[PTR:%.*]] = getelementptr i8, ptr %p, i32 1
; CHECK-DAG: [[HIGH:%.*]] = load i8, ptr [[PTR]], align 1
; CHECK-DAG: [[LOW:%.*]] = load i8, ptr %p, align 1
; CHECK-NEXT: call void @clobber(ptr %p)
; CHECK-NEXT: %sum = add i8 [[LOW]], [[HIGH]]
; CHECK-NEXT: ret i8 %sum
entry:
  %before = load i16, ptr %p, align 1
  call void @clobber(ptr %p)
  %low = trunc i16 %before to i8
  %shift = lshr i16 %before, 8
  %high = trunc i16 %shift to i8
  %sum = add i8 %low, %high
  ret i8 %sum
}

define i8 @shifted_consumer_in_successor(ptr %p, i8 %replacement) {
; CHECK-LABEL: define i8 @shifted_consumer_in_successor(
; CHECK: entry:
; CHECK-NEXT: [[PTR:%.*]] = getelementptr i8, ptr %p, i32 1
; CHECK-NEXT: [[HIGH:%.*]] = load i8, ptr [[PTR]], align 1
; CHECK-NEXT: br label %next
; CHECK: next:
; CHECK-NEXT: store volatile i8 %replacement, ptr %p, align 1
; CHECK-NEXT: ret i8 [[HIGH]]
entry:
  %before = load i16, ptr %p, align 1
  %shift = lshr i16 %before, 8
  br label %next

next:
  store volatile i8 %replacement, ptr %p, align 1
  %high = trunc i16 %shift to i8
  ret i8 %high
}

; Unsupported users must leave the entire candidate untouched, regardless of
; whether a supported user appears before or after them in the use list.
define i32 @unsupported_user_first(ptr %p) {
; CHECK-LABEL: define i32 @unsupported_user_first(
; CHECK: entry:
; CHECK-NEXT: %before = load i16, ptr %p, align 1
; CHECK-NEXT: %wide = zext i16 %before to i32
; CHECK-NEXT: %low = trunc i16 %before to i8
; CHECK-NEXT: call void @consume(i8 %low)
; CHECK-NEXT: ret i32 %wide
entry:
  %before = load i16, ptr %p, align 1
  %wide = zext i16 %before to i32
  %low = trunc i16 %before to i8
  call void @consume(i8 %low)
  ret i32 %wide
}

define i32 @unsupported_user_last(ptr %p) {
; CHECK-LABEL: define i32 @unsupported_user_last(
; CHECK: entry:
; CHECK-NEXT: %before = load i16, ptr %p, align 1
; CHECK-NEXT: %low = trunc i16 %before to i8
; CHECK-NEXT: %wide = zext i16 %before to i32
; CHECK-NEXT: call void @consume(i8 %low)
; CHECK-NEXT: ret i32 %wide
entry:
  %before = load i16, ptr %p, align 1
  %low = trunc i16 %before to i8
  %wide = zext i16 %before to i32
  call void @consume(i8 %low)
  ret i32 %wide
}

define i8 @unsupported_shared_shift(ptr %p) {
; CHECK-LABEL: define i8 @unsupported_shared_shift(
; CHECK: entry:
; CHECK-NEXT: %before = load i16, ptr %p, align 1
; CHECK-NEXT: %shift = lshr i16 %before, 8
; CHECK-NEXT: %first = trunc i16 %shift to i8
; CHECK-NEXT: %second = trunc i16 %shift to i8
; CHECK-NEXT: %low = trunc i16 %before to i8
; CHECK-NEXT: call void @consume(i8 %first)
; CHECK-NEXT: call void @consume(i8 %second)
; CHECK-NEXT: ret i8 %low
entry:
  %before = load i16, ptr %p, align 1
  %shift = lshr i16 %before, 8
  %first = trunc i16 %shift to i8
  %second = trunc i16 %shift to i8
  %low = trunc i16 %before to i8
  call void @consume(i8 %first)
  call void @consume(i8 %second)
  ret i8 %low
}

define i8 @unaligned_bit_shift(ptr %p) {
; CHECK-LABEL: define i8 @unaligned_bit_shift(
; CHECK: entry:
; CHECK-NEXT: %before = load i16, ptr %p, align 1
; CHECK-NEXT: %shift = lshr i16 %before, 3
; CHECK-NEXT: %low = trunc i16 %shift to i8
; CHECK-NEXT: ret i8 %low
entry:
  %before = load i16, ptr %p, align 1
  %shift = lshr i16 %before, 3
  %low = trunc i16 %shift to i8
  ret i8 %low
}

define i8 @aligned_load(ptr %p) {
; CHECK-LABEL: define i8 @aligned_load(
; CHECK: entry:
; CHECK-NEXT: %before = load i16, ptr %p, align 2
; CHECK-NEXT: %low = trunc i16 %before to i8
; CHECK-NEXT: ret i8 %low
entry:
  %before = load i16, ptr %p, align 2
  %low = trunc i16 %before to i8
  ret i8 %low
}

define i8 @volatile_load(ptr %p) {
; CHECK-LABEL: define i8 @volatile_load(
; CHECK: entry:
; CHECK-NEXT: %before = load volatile i16, ptr %p, align 1
; CHECK-NEXT: %low = trunc i16 %before to i8
; CHECK-NEXT: ret i8 %low
entry:
  %before = load volatile i16, ptr %p, align 1
  %low = trunc i16 %before to i8
  ret i8 %low
}

define i8 @atomic_load(ptr %p) {
; CHECK-LABEL: define i8 @atomic_load(
; CHECK: entry:
; CHECK-NEXT: %before = load atomic i16, ptr %p syncscope("singlethread") monotonic, align 1
; CHECK-NEXT: %low = trunc i16 %before to i8
; CHECK-NEXT: ret i8 %low
entry:
  %before = load atomic i16, ptr %p syncscope("singlethread") monotonic, align 1
  %low = trunc i16 %before to i8
  ret i8 %low
}

define i8 @unsupported_load_width(ptr %p) {
; CHECK-LABEL: define i8 @unsupported_load_width(
; CHECK: entry:
; CHECK-NEXT: %before = load i64, ptr %p, align 1
; CHECK-NEXT: %low = trunc i64 %before to i8
; CHECK-NEXT: ret i8 %low
entry:
  %before = load i64, ptr %p, align 1
  %low = trunc i64 %before to i8
  ret i8 %low
}
