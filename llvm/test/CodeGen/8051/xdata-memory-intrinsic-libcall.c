// XDATA (address space 4) memory intrinsics that the generic inline expansion
// declines must become the same runtime calls as their default-address-space
// equivalents instead of aborting with "cannot lower memory intrinsic in
// address space 4".
// RUN: clang -target mcs51 -mcpu=cc2530 -O0 -mllvm -verify-machineinstrs \
// RUN:   -S %s -o - | FileCheck %s
// RUN: clang -target mcs51 -mcpu=cc2530 -O2 -mllvm -verify-machineinstrs \
// RUN:   -S %s -o - | FileCheck %s
// RUN: clang -target mcs51 -mcpu=cc2530 -Os -mllvm -verify-machineinstrs \
// RUN:   -S %s -o - | FileCheck %s

typedef struct {
  unsigned char Bytes[10];
} Ten;
typedef struct {
  unsigned char Bytes[6];
} Six;
typedef struct {
  unsigned char Bytes[2];
} Two;

__xdata Ten XTen, XTenCopy;
__xdata Six XSix, XSixCopy;
__xdata Two XTwo, XTwoCopy;
__xdata unsigned char XBuffer[64];
__xdata unsigned char XOther[64];

void copy_struct10(void) { XTenCopy = XTen; }
// CHECK-LABEL: copy_struct10:
// CHECK: lcall __mcs51_bankcall_memcpy

void copy_struct6(void) { XSixCopy = XSix; }
// CHECK-LABEL: copy_struct6:
// CHECK: lcall __mcs51_bankcall_memcpy

void copy_xdata_40(void) { __builtin_memcpy(XBuffer, XOther, 40); }
// CHECK-LABEL: copy_xdata_40:
// CHECK: lcall __mcs51_bankcall_memcpy

void copy_from_default(const unsigned char *Source) {
  __builtin_memcpy(XBuffer, Source, 40);
}
// CHECK-LABEL: copy_from_default:
// CHECK: lcall __mcs51_bankcall_memcpy

void copy_to_default(unsigned char *Destination) {
  __builtin_memcpy(Destination, XBuffer, 40);
}
// CHECK-LABEL: copy_to_default:
// CHECK: lcall __mcs51_bankcall_memcpy

void copy_absolute(void) {
  __builtin_memcpy((__xdata unsigned char *)0x1c00, XOther, 24);
}
// CHECK-LABEL: copy_absolute:
// CHECK: lcall __mcs51_bankcall_memcpy

void set_xdata_64(void) { __builtin_memset(XBuffer, 0, 64); }
// CHECK-LABEL: set_xdata_64:
// CHECK: lcall __mcs51_bankcall_memset

void set_xdata_variable(unsigned char Count) {
  __builtin_memset(XBuffer, 0x5a, Count);
}
// CHECK-LABEL: set_xdata_variable:
// CHECK: lcall __mcs51_bankcall_memset

void move_xdata_40(void) { __builtin_memmove(XBuffer + 1, XBuffer, 40); }
// CHECK-LABEL: move_xdata_40:
// CHECK: lcall __mcs51_bankcall_memmove

// Unchanged paths: a small copy stays inline, a stack object is still copied
// with @Ri, and a variable-size copy is still MCS51GenericPointerLowering's
// MOVX loop.
void copy_struct2(void) { XTwoCopy = XTwo; }
// CHECK-LABEL: copy_struct2:
// CHECK-NOT: lcall
// CHECK: ret

extern void fill(unsigned char *Buffer);

void copy_stack_to_xdata(void) {
  unsigned char Local[12];
  fill(Local);
  __builtin_memcpy(XBuffer, Local, sizeof(Local));
}
// CHECK-LABEL: copy_stack_to_xdata:
// CHECK: lcall __mcs51_bankcall_fill
// CHECK-NOT: lcall __mcs51_bankcall_memcpy
// CHECK: mov a, @r{{[01]}}
// CHECK: movx @dptr, a
// CHECK-NOT: lcall __mcs51_bankcall_memcpy
// CHECK: ret

void copy_xdata_variable(unsigned int Count) {
  __builtin_memcpy(XBuffer, XOther, Count);
}
// CHECK-LABEL: copy_xdata_variable:
// CHECK: movx a, @dptr
// CHECK: movx @dptr, a
// CHECK-NOT: lcall __mcs51_bankcall_memcpy
// CHECK: ret
