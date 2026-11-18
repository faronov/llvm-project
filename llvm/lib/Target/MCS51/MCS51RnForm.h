//===-- MCS51RnForm.h - Rn forms of bank-0 direct operands ------*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_LIB_TARGET_MCS51_MCS51RNFORM_H
#define LLVM_LIB_TARGET_MCS51_MCS51RNFORM_H

#include "MCTargetDesc/MCS51MCTargetDesc.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/MC/MCInst.h"
#include "llvm/MC/MCRegisterInfo.h"
#include <initializer_list>

namespace llvm {
namespace mcs51 {

// -mcs51-rn-words: R0-R7 of bank 0 also appear as direct addresses 0-7, either
// as the imaginary-register aliases IMR0-IMR3 or as direct operands that name
// a register's bank-0 address. Their Rn instruction forms are one byte
// shorter. Returns the Rn register for such an operand, or 0.
inline MCRegister rnOf(const MCOperand &Op) {
  if (Op.isReg()) {
    switch (Op.getReg()) {
    case MCS51::IMR0: return MCS51::R2;
    case MCS51::IMR1: return MCS51::R3;
    case MCS51::IMR2: return MCS51::R4;
    case MCS51::IMR3: return MCS51::R5;
    default: return MCRegister();
    }
  }
  if (Op.isImm() && Op.getImm() >= 0 && Op.getImm() < 8)
    return MCRegister(MCS51::R0 + Op.getImm());
  return MCRegister();
}

// Rewrites In into its Rn form. Returns false when In has none; sets Drop for
// a move of a register onto itself.
inline bool getRnForm(const MCInst &In, MCInst &Out, bool &Drop,
                      const MCRegisterInfo &MRI) {
  Drop = false;
  // An imaginary register as the direct operand of a non-imaginary form.
  auto Direct = [&](const MCOperand &Op) {
    return Op.isReg() ? MCOperand::createImm(MRI.getEncodingValue(Op.getReg()))
                      : Op;
  };
  auto Make = [&](unsigned Opcode, std::initializer_list<MCOperand> Ops) {
    Out.clear();
    Out.setOpcode(Opcode);
    for (const MCOperand &Op : Ops)
      Out.addOperand(Op);
    return true;
  };
  auto Reg = [](MCRegister R) { return MCOperand::createReg(R); };
  auto AccOp = [&](unsigned Opcode, const MCOperand &Src) {
    MCRegister R = rnOf(Src);
    return R && Make(Opcode, {Reg(R)});
  };
  switch (In.getOpcode()) {
  // A-relative forms: [A, src] or [src].
  case MCS51::MOV_A_IM:
  case MCS51::MOV_A_DIRECT:
    return AccOp(MCS51::MOV_A_RN, In.getOperand(1));
  case MCS51::ADD_A_DIRECT:
    return AccOp(MCS51::ADD_A_RN, In.getOperand(1));
  case MCS51::ADDC_A_DIRECT:
    return AccOp(MCS51::ADDC_A_RN, In.getOperand(1));
  case MCS51::SUBB_A_DIRECT:
    return AccOp(MCS51::SUBB_A_RN, In.getOperand(1));
  case MCS51::ANL_A_DIRECT:
    return AccOp(MCS51::ANL_A_RN, In.getOperand(1));
  case MCS51::ORL_A_DIRECT:
    return AccOp(MCS51::ORL_A_RN, In.getOperand(1));
  case MCS51::XRL_A_DIRECT:
    return AccOp(MCS51::XRL_A_RN, In.getOperand(1));
  case MCS51::ADD_A_IM:
    return AccOp(MCS51::ADD_A_RN, In.getOperand(0));
  case MCS51::ADDC_A_IM:
    return AccOp(MCS51::ADDC_A_RN, In.getOperand(0));
  case MCS51::SUBB_A_IM:
    return AccOp(MCS51::SUBB_A_RN, In.getOperand(0));
  case MCS51::ANL_A_IM:
    return AccOp(MCS51::ANL_A_RN, In.getOperand(0));
  case MCS51::ORL_A_IM:
    return AccOp(MCS51::ORL_A_RN, In.getOperand(0));
  case MCS51::XRL_A_IM:
    return AccOp(MCS51::XRL_A_RN, In.getOperand(0));
  case MCS51::XCH_A_DIRECT: {
    MCRegister R = rnOf(In.getOperand(1));
    return R && Make(MCS51::XCH_A_RN, {Reg(R), Reg(R)});
  }
  case MCS51::MOV_IM_A:
  case MCS51::MOV_DIRECT_A: {
    MCRegister R = rnOf(In.getOperand(0));
    return R && Make(MCS51::MOV_RN_A, {Reg(R)});
  }
  case MCS51::MOV_IM_SYMLO:
  case MCS51::MOV_IM_SYMHI:
  case MCS51::MOV_IM_SYMLO_XDATA:
  case MCS51::MOV_IM_SYMHI_XDATA:
  case MCS51::MOV_IM_SYMLO_CODE:
  case MCS51::MOV_IM_SYMHI_CODE: {
    static const DenseMap<unsigned, unsigned> RnSym = {
        {MCS51::MOV_IM_SYMLO, MCS51::MOV_RN_SYMLO},
        {MCS51::MOV_IM_SYMHI, MCS51::MOV_RN_SYMHI},
        {MCS51::MOV_IM_SYMLO_XDATA, MCS51::MOV_RN_SYMLO_XDATA},
        {MCS51::MOV_IM_SYMHI_XDATA, MCS51::MOV_RN_SYMHI_XDATA},
        {MCS51::MOV_IM_SYMLO_CODE, MCS51::MOV_RN_SYMLO_CODE},
        {MCS51::MOV_IM_SYMHI_CODE, MCS51::MOV_RN_SYMHI_CODE}};
    MCRegister R = rnOf(In.getOperand(0));
    return R && Make(RnSym.at(In.getOpcode()), {Reg(R), In.getOperand(1)});
  }
  case MCS51::MOV_IM_IMM:
  case MCS51::MOV_DIRECT_IMM: {
    MCRegister R = rnOf(In.getOperand(0));
    return R && Make(MCS51::MOV_RN_IMM, {Reg(R), In.getOperand(1)});
  }
  case MCS51::INC_DIRECT:
  case MCS51::DEC_DIRECT: {
    MCRegister R = rnOf(In.getOperand(0));
    unsigned Opcode =
        In.getOpcode() == MCS51::INC_DIRECT ? MCS51::INC_RN : MCS51::DEC_RN;
    return R && Make(Opcode, {Reg(R), Reg(R)});
  }
  case MCS51::DJNZ_DIRECT: {
    MCRegister R = rnOf(In.getOperand(0));
    return R && Make(MCS51::DJNZ_RN, {Reg(R), Reg(R), In.getOperand(1)});
  }
  // Byte moves between two direct operands: [dst, src].
  case MCS51::MOV_IM_IM:
  case MCS51::MOV_IM_DIRECT:
  case MCS51::MOV_DIRECT_IM:
  case MCS51::MOV_DIRECT_DIRECT: {
    MCRegister Dst = rnOf(In.getOperand(0)), Src = rnOf(In.getOperand(1));
    if (Dst && Dst == Src)
      return Drop = true;
    if (Dst)
      return Make(MCS51::MOV_RN_DIRECT, {Reg(Dst), Direct(In.getOperand(1))});
    if (Src)
      return Make(MCS51::MOV_DIRECT_RN, {Direct(In.getOperand(0)), Reg(Src)});
    return false;
  }
  case MCS51::MOV_IM_RN:
  case MCS51::MOV_DIRECT_RN:
    if (rnOf(In.getOperand(0)) == In.getOperand(1).getReg())
      return Drop = true;
    return false;
  case MCS51::MOV_RN_IM:
  case MCS51::MOV_RN_DIRECT:
    if (rnOf(In.getOperand(1)) == In.getOperand(0).getReg())
      return Drop = true;
    return false;
  default:
    return false;
  }
}

} // namespace mcs51
} // namespace llvm

#endif
