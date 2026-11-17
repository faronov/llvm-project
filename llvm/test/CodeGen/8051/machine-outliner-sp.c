// RUN: clang -target mcs51 -mcpu=cc2530 -Oz -S %s -o - | FileCheck %s

// Frame addresses are computed from SP (direct address 0x81). An outlined
// helper runs with its return address on the stack, so instructions that read
// SP must stay in the caller.

void sink(char *);
void first(char v) { char b[3]; b[0] = v; b[1] = 2; sink(b); }
void second(char v) { char b[3]; b[0] = v; b[1] = 2; sink(b); }
void third(char v) { char b[3]; b[0] = v; b[1] = 2; sink(b); }

// CHECK-LABEL: first:
// CHECK: mov a, 129
// CHECK-NOT: {{^OUTLINED_FUNCTION_[0-9]+:}}
// CHECK-LABEL: third:
// CHECK: mov a, 129
// CHECK-NOT: mov a, 129
