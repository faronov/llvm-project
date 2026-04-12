// RUN: llvm-mc -triple=tc32 -filetype=obj %s -o %t
// RUN: llvm-objdump --triple=tc32 -d %t | FileCheck %s

        .text
        .code 16
        .globl test_tc32_disasm
test_tc32_disasm:
        .short 0x87fe
        .short 0x640c
        .short 0xa001
        .short 0xa802
        .short 0x5841
        .short 0x5081
        .short 0xf0d2
        .short 0x6bc0
        .short 0x6bdf
        .short 0x6bd1
        .short 0x6900
        .short 0x6c0c
        .short 0x0770
        .short 0x0688
        .short 0x0641
        .short 0x0588
        .short 0x0441
        .short 0x0800
        .short 0x97ff
        .short 0x9ffe

// CHECK-LABEL: <test_tc32_disasm>:
// CHECK:      tj
// CHECK:      tpush{{[ \t]+}}{r2, r3}
// CHECK:      tmov{{[ \t]+}}r0, #0x1
// CHECK:      tcmp{{[ \t]+}}r0, #0x2
// CHECK:      tloadr{{[ \t]+}}r1, [r0, #0x4]
// CHECK:      tstorer{{[ \t]+}}r1, [r0, #0x8]
// CHECK:      tshftl{{[ \t]+}}r2, r2, #0x3
// CHECK:      tmcsr{{[ \t]+}}r0
// CHECK:      tmrss{{[ \t]+}}r7
// CHECK:      tmssr{{[ \t]+}}r1
// CHECK:      treti{{[ \t]+}}{r15}
// CHECK:      tpop{{[ \t]+}}{r2, r3}
// CHECK:      tjex{{[ \t]+}}lr
// CHECK:      tmov{{[ \t]+}}r8, r1
// CHECK:      tmov{{[ \t]+}}r1, r8
// CHECK:      tcmp{{[ \t]+}}r8, r1
// CHECK:      tadd{{[ \t]+}}r1, r8
// CHECK:      tloadr{{[ \t]+}}r0, [pc, #0x0]
// CHECK:      tjl
