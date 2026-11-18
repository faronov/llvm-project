// Argument rules shared by the C convention and the IM-word convention.
def CC_MCS51_Head : CallingConv<[
  CCIfVarArg<CCIfType<[i8], CCAssignToStack<1, 1>>>,
  CCIfVarArg<CCIfType<[i16], CCAssignToStack<2, 1>>>,
  // A 64-bit argument goes on the stack, word by word.
  CCIf<"OrigTy->isIntegerTy(64)", CCIfType<[i16], CCAssignToStack<2, 1>>>
]>;
def CC_MCS51_Tail : CallingConv<[
  CCIfType<[i16], CCAssignToReg<[IP0, IP1, IP2, IP3]>>,
  CCIfType<[i8], CCAssignToReg<[R7, R6, R5, R4]>>,
  // Experimental -mcs51-wide-args: continue in caller-saved imaginary
  // registers before using the hardware stack.
  CCIf<"llvm::mcs51WideArgs()",
       CCIfType<[i16], CCAssignToReg<[IP4, IP5, IP6, IP7]>>>,
  CCIf<"llvm::mcs51WideArgs()",
       CCIfType<[i8], CCAssignToReg<[IM16, IM17, IM18, IM19,
                                     IM20, IM21, IM22, IM23]>>>,
  CCIfType<[i8], CCAssignToStack<1, 1>>,
  CCIfType<[i16], CCAssignToStack<2, 1>>
]>;

def CC_MCS51 : CallingConv<[
  CCDelegateTo<CC_MCS51_Head>,
  // Words travel in imaginary pairs, low word of a wider value first.
  // -mcs51-rn-words moves the first two into R2R3 and R4R5 and the fifth and
  // sixth into the IP0 and IP1 they free; a word in R4R5 shadows the byte
  // argument registers it overlaps.
  CCIf<"llvm::mcs51RnWords()",
       CCIfType<[i16], CCAssignToReg<[IPR0, IPR1, IP2, IP3, IP0, IP1]>>>,
  CCDelegateTo<CC_MCS51_Tail>
]>;

// Hand-written runtime helpers address their words as IP0-IP3 (direct 48-55)
// whatever -mcs51-rn-words selects.
def CC_MCS51_IMWords : CallingConv<[
  CCDelegateTo<CC_MCS51_Head>,
  CCDelegateTo<CC_MCS51_Tail>
]>;

def RetCC_MCS51 : CallingConv<[
  CCIfType<[i8], CCAssignToReg<[A]>>,
  CCIf<"llvm::mcs51RnWords()",
       CCIfType<[i16], CCAssignToReg<[IPR0, IPR1, IP2, IP3]>>>,
  CCIfType<[i16], CCAssignToReg<[IP0, IP1, IP2, IP3]>>
]>;
def RetCC_MCS51_IMWords : CallingConv<[
  CCIfType<[i8], CCAssignToReg<[A]>>,
  CCIfType<[i16], CCAssignToReg<[IP0, IP1, IP2, IP3]>>
]>;

// R2-R7 and IM8-IM23 are callee-saved. This lets values remain in registers
// across calls instead of spilling each one through the 8051's expensive
// SP-relative path. IM0-IM7 carry arguments and results.
def CSR_MCS51 : CalleeSavedRegs<(add R2, R3, R4, R5, R6, R7,
                                    (sequence "IM%d", 8, 23))>;

// Reduced callee-saved sets selected by -mcs51-csr (default unchanged).
def CSR_MCS51_R : CalleeSavedRegs<(add R2, R3, R4, R5, R6, R7)>;
def CSR_MCS51_None : CalleeSavedRegs<(add)>;
