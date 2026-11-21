# RUN: llvm-mc -triple=mcs51 -filetype=obj %s -o %t.o
# RUN: ld.lld -m elf32-mcs51 -T %S/../../../llvm/lib/Target/MCS51/cc2530.ld \
# RUN:   --no-check-sections -o %t.elf %t.o
# RUN: llvm-objdump -d %t.elf | FileCheck %s

# A call or tail jump through a ".direct." trampoline whose callee lies in
# common flash goes straight to the callee from common and from any bank.
# Function addresses and trampolines without the marker (incoming stack
# arguments) keep the trampoline.
.section .vectors,"ax"
.globl reset
reset:
  lcall __mcs51_bankcall_helper
  ret

.section .bank1.caller,"ax"
.globl caller
.type caller,@function
caller:
  lcall __mcs51_bankcall_helper
  lcall __mcs51_bankcall_stackarg
  mov dptr, #__mcs51_bankcall_helper
  ljmp __mcs51_bankcall_helper

.section .mcs51.common.helper,"ax"
.globl helper
.type helper,@function
helper:
  ret

.section .mcs51.common.stackarg,"ax"
.globl stackarg
.type stackarg,@function
stackarg:
  ret

.section .text.autobankthunks.direct.0,"ax"
.globl __mcs51_bankcall_helper
__mcs51_bankcall_helper:
  push 159
  mov 159, #helper
  lcall helper
  pop 159
  ret

.section .text.autobankthunks.1,"ax"
.globl __mcs51_bankcall_stackarg
__mcs51_bankcall_stackarg:
  push 159
  mov 159, #stackarg
  lcall stackarg
  pop 159
  ret

# CHECK:      <reset>:
# CHECK-NEXT:   11 94        acall 148
# CHECK:      00000094 <helper>:
# CHECK:      00000095 <stackarg>:
# CHECK:      00000098 <__mcs51_bankcall_helper>:
# CHECK:      000000a3 <__mcs51_bankcall_stackarg>:
# CHECK:      00008000 <caller>:
# CHECK-NEXT:   12 00 94     lcall 148
# CHECK-NEXT:   12 00 a3     lcall 163
# CHECK-NEXT:   90 00 98     mov dptr, #152
# CHECK-NEXT:   02 00 94     ljmp 148
