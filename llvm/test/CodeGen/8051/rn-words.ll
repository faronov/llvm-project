; -mcs51-rn-words passes the first two argument words and the result word in
; R2R3/R4R5 (bank 0) instead of IM0-IM3, so the AsmPrinter can emit the
; one-byte-shorter Rn instruction forms for them.
; RUN: llc -mtriple=mcs51 -mcs51-csr=none -mcs51-rn-words < %s | FileCheck %s
; RUN: llc -mtriple=mcs51 -mcs51-csr=none -mcs51-rn-words -filetype=obj < %s \
; RUN:   | llvm-objdump -dr - | FileCheck %s --check-prefix=OBJ
; RUN: llc -mtriple=mcs51 -mcs51-csr=none < %s | FileCheck %s --check-prefix=IM
; R2-R5 are callee-saved under the default and r sets, so the option is refused.
; RUN: not --crash llc -mtriple=mcs51 -mcs51-rn-words < %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=REFUSE
; RUN: not --crash llc -mtriple=mcs51 -mcs51-csr=r -mcs51-rn-words < %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=REFUSE
; REFUSE: -mcs51-rn-words requires -mcs51-csr=none

@buf = external global [16 x i8]
@gv = external global i16

declare i16 @g(i16, i16, i8)
declare void @use(ptr, ptr)

; CHECK-LABEL: args:
; CHECK:      mov a, r2
; CHECK-NEXT: add a, r4
; CHECK-NEXT: mov r2, a
; CHECK-NEXT: mov a, r3
; CHECK-NEXT: addc a, r5
; CHECK-NEXT: mov r3, a
; CHECK-NEXT: ret
; IM-LABEL: args:
; IM:      mov a, 48
; IM-NEXT: add a, 50
define i16 @args(i16 %a, i16 %b) {
  %s = add i16 %a, %b
  ret i16 %s
}

; CHECK-LABEL: call:
; CHECK:      mov r4, 54
; CHECK-NEXT: mov r5, 55
; CHECK-NEXT: lcall g
; CHECK-NEXT: mov a, r2
define i16 @call(i16 %a, i16 %b, i8 %c) {
  %s = add i16 %a, %b
  %z = zext i8 %c to i16
  %t = xor i16 %s, %z
  %r = call i16 @g(i16 %t, i16 %a, i8 %c)
  %q = add i16 %r, %b
  ret i16 %q
}

; CHECK-LABEL: syms:
; CHECK:      mov r2, #xlo8(buf+3)
; CHECK-NEXT: mov r3, #xhi8(buf+3)
; CHECK-NEXT: mov r4, #xlo8(gv)
; CHECK-NEXT: mov r5, #xhi8(gv)
; CHECK-NEXT: lcall use
; IM-LABEL: syms:
; IM:      mov 48, #xlo8(buf+3)
; OBJ-LABEL: <syms>:
; OBJ:      7a 00 mov r2, #0
; OBJ-NEXT: R_8051_LO8_XDATA buf+0x3
; OBJ:      7b 00 mov r3, #0
; OBJ-NEXT: R_8051_HI8_XDATA buf+0x3
; OBJ:      7c 00 mov r4, #0
; OBJ-NEXT: R_8051_LO8_XDATA gv
; OBJ:      7d 00 mov r5, #0
; OBJ-NEXT: R_8051_HI8_XDATA gv
define void @syms() {
  call void @use(ptr getelementptr (i8, ptr @buf, i16 3), ptr @gv)
  ret void
}

; The assembly shift helpers keep their operands in IP0-IP2 (48-53).
; CHECK-LABEL: shl32:
; CHECK:      mov 50, r4
; CHECK-NEXT: mov 51, r5
; CHECK-NEXT: mov 48, r2
; CHECK-NEXT: mov 49, r3
; CHECK-NEXT: lcall __ashlsi3
; CHECK-NEXT: mov r2, 48
; CHECK-NEXT: mov r3, 49
; CHECK-NEXT: mov r4, 50
; CHECK-NEXT: mov r5, 51
; IM-LABEL: shl32:
; IM-NEXT: ; %bb.0:
; IM-NEXT: lcall __ashlsi3
define i32 @shl32(i32 %v, i32 %n) {
  %r = shl i32 %v, %n
  ret i32 %r
}

; The interrupt frame saves the bank-0 registers holding words by address.
; CHECK-LABEL: isr:
; CHECK:      push 2{{$}}
; CHECK-NEXT: push 3{{$}}
; CHECK-NEXT: push 4{{$}}
; CHECK-NEXT: push 5{{$}}
; CHECK:      pop 5{{$}}
; CHECK-NEXT: pop 4{{$}}
; CHECK-NEXT: pop 3{{$}}
; CHECK-NEXT: pop 2{{$}}
; CHECK:      reti
define void @isr() #0 {
  %v = load volatile i16, ptr inttoptr (i16 4660 to ptr)
  %w = add i16 %v, 3
  store volatile i16 %w, ptr inttoptr (i16 4662 to ptr)
  ret void
}

attributes #0 = { "interrupt"="1" }
