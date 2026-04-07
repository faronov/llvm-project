// RUN: llvm-mc -triple=tc32 -filetype=obj %s -o %t
// RUN: llvm-objdump --triple=tc32 -d %t | FileCheck %s

        .text
        .code 16
aliases:
        tor     r3, r4
        tand    r1, r0
        txor    r1, r0
        tbclr   r1, r0
        tsub    r3, r3, #8
        tmrcs   r3
        tjne    aliases
        tjls    aliases
        orr     r1, r2

// CHECK-LABEL: <aliases>:
// CHECK:      tor{{[ \t]+}}r3, r4
// CHECK:      tand{{[ \t]+}}r1, r0
// CHECK:      txor{{[ \t]+}}r1, r0
// CHECK:      tbclr{{[ \t]+}}r1, r0
// CHECK:      tsub{{[ \t]+}}r3, #0x8
// CHECK:      tmrss{{[ \t]+}}r3
// CHECK:      tjne
// CHECK:      tjls
// CHECK:      tor{{[ \t]+}}r1, r2
