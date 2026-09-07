//===-- TC32PackedByteLoadStorePass.cpp - Scalarize packed loads ----------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "ARM.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/BasicBlock.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Instruction.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/LegacyPassManager.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Type.h"
#include "llvm/Pass.h"

using namespace llvm;

#define DEBUG_TYPE "tc32-packed-byte-load-store"

namespace {

static Value *createPackedByteLoad(LoadInst &LI, uint64_t ByteOffset) {
  IRBuilder<> B(&LI);
  Type *I8Ty = B.getInt8Ty();
  Value *BasePtr = LI.getPointerOperand();
  Value *BytePtr = BasePtr;
  if (ByteOffset != 0)
    BytePtr = B.CreateConstGEP1_32(I8Ty, BasePtr, ByteOffset);
  auto *NewLoad = B.CreateLoad(I8Ty, BytePtr);
  NewLoad->setAlignment(Align(1));
  NewLoad->setVolatile(LI.isVolatile());
  if (LI.isAtomic())
    NewLoad->setAtomic(LI.getOrdering(), LI.getSyncScopeID());
  return NewLoad;
}

class TC32PackedByteLoadStorePass : public FunctionPass {
public:
  static char ID;

  TC32PackedByteLoadStorePass() : FunctionPass(ID) {}

  StringRef getPassName() const override {
    return "TC32 Packed Byte Load Scalarization";
  }

  bool runOnFunction(Function &F) override {
    return runTC32PackedByteLoadStore(F);
  }
};

} // namespace

bool llvm::runTC32PackedByteLoadStore(Function &F) {
  if (!F.getParent()->getTargetTriple().isTC32())
    return false;

  SmallVector<LoadInst *, 32> Candidates;
  for (BasicBlock &BB : F) {
    for (Instruction &I : BB) {
      auto *LI = dyn_cast<LoadInst>(&I);
      if (!LI || LI->isVolatile() || LI->isAtomic())
        continue;
      if (LI->getAlign().value() > 1)
        continue;
      Type *Ty = LI->getType();
      if (Ty != Type::getInt16Ty(F.getContext()) &&
          Ty != Type::getInt32Ty(F.getContext()))
        continue;
      Candidates.push_back(LI);
    }
  }

  bool Changed = false;
  for (LoadInst *LI : Candidates) {
    if (LI->use_empty())
      continue;

    unsigned BitWidth = cast<IntegerType>(LI->getType())->getBitWidth();
    SmallVector<Instruction *, 8> Shifts;
    SmallVector<std::pair<TruncInst *, uint64_t>, 8> Replacements;
    bool Valid = true;

    for (User *U : LI->users()) {
      auto *Inst = dyn_cast<Instruction>(U);
      if (!Inst || Inst->getParent() != LI->getParent()) {
        Valid = false;
        break;
      }

      if (auto *Tr = dyn_cast<TruncInst>(Inst)) {
        if (Tr->getDestTy() != Type::getInt8Ty(F.getContext())) {
          Valid = false;
          break;
        }
        Replacements.push_back({Tr, 0});
        continue;
      }

      auto *LS = dyn_cast<LShrOperator>(Inst);
      if (!LS || !isa<ConstantInt>(LS->getOperand(1))) {
        Valid = false;
        break;
      }

      uint64_t Shift = cast<ConstantInt>(LS->getOperand(1))->getZExtValue();
      if ((Shift & 7) != 0 || Shift >= BitWidth) {
        Valid = false;
        break;
      }

      if (!Inst->hasOneUse()) {
        Valid = false;
        break;
      }

      auto *Tr = dyn_cast<TruncInst>(*Inst->user_begin());
      if (!Tr || Tr->getDestTy() != Type::getInt8Ty(F.getContext())) {
        Valid = false;
        break;
      }

      Replacements.push_back({Tr, Shift / 8});
      Shifts.push_back(Inst);
    }

    if (!Valid)
      continue;

    // Validate every use before changing IR, and preserve the original memory
    // snapshot even when a consumer follows an aliasing write or call.
    Value *Bytes[4] = {};
    for (auto &[Tr, ByteOffset] : Replacements) {
      if (!Bytes[ByteOffset])
        Bytes[ByteOffset] = createPackedByteLoad(*LI, ByteOffset);
      Tr->replaceAllUsesWith(Bytes[ByteOffset]);
      Tr->eraseFromParent();
    }

    for (Instruction *I : Shifts)
      I->eraseFromParent();

    LI->eraseFromParent();
    Changed = true;
  }

  return Changed;
}

char TC32PackedByteLoadStorePass::ID = 0;

INITIALIZE_PASS(TC32PackedByteLoadStorePass, DEBUG_TYPE,
                "TC32 packed byte load/store scalarization", false, false)

FunctionPass *llvm::createTC32PackedByteLoadStorePass() {
  return new TC32PackedByteLoadStorePass();
}
