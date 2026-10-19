#include "MCS51SelectionDAGInfo.h"
#include "MCS51.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/Analysis/TargetLibraryInfo.h"
#include "llvm/CodeGen/LibcallLoweringInfo.h"
#include "llvm/CodeGen/SelectionDAG.h"
#include "llvm/CodeGen/TargetLowering.h"
#include "llvm/IR/DerivedTypes.h"
#include "llvm/Support/Casting.h"

#define GET_SDNODE_DESC
#include "MCS51GenSDNodeInfo.inc"

using namespace llvm;

MCS51SelectionDAGInfo::MCS51SelectionDAGInfo()
    : SelectionDAGGenTargetInfo(MCS51GenSDNodeInfo) {}

MCS51SelectionDAGInfo::~MCS51SelectionDAGInfo() = default;

static bool containsFrameIndex(SDValue Value) {
  SmallVector<SDValue, 8> Worklist(1, Value);
  while (!Worklist.empty()) {
    SDValue Current = Worklist.pop_back_val();
    if (Current.getOpcode() == ISD::FrameIndex)
      return true;
    if (Current.getOpcode() == ISD::ADD ||
        Current.getOpcode() == ISD::BITCAST ||
        Current.getOpcode() == ISD::ADDRSPACECAST)
      for (SDValue Operand : Current->ops())
        Worklist.push_back(Operand);
  }
  return false;
}

static bool usesAddressSpaceAwareMemcpy(unsigned AddressSpace) {
  switch (AddressSpace) {
  case MCS51::Data:
  case MCS51::IData:
  case MCS51::PData:
  case MCS51::Code:
  case MCS51::SFR:
    return true;
  default:
    return false;
  }
}

// XDATA (AS4) and the default address space (AS0) outside the stack are the
// same 16-bit MOVX bus: instruction selection lowers such AS0 accesses with
// MOVX, MCS51GenericPointerLowering treats Default as XData, and the runtime
// memcpy/memmove/memset take AS0 pointers. Generic SelectionDAG only emits
// those libcalls for AS0 operands and otherwise aborts with "cannot lower
// memory intrinsic in address space 4". A pointer qualifies when no stack
// object or cast from another bus contributes to its address.
static bool isOnXDataBus(SDValue Pointer, const MachinePointerInfo &Info) {
  unsigned AddressSpace = Info.getAddrSpace();
  if (AddressSpace != MCS51::XData && AddressSpace != MCS51::Default)
    return false;
  SmallVector<SDValue, 8> Worklist(1, Pointer);
  while (!Worklist.empty()) {
    SDValue Current = Worklist.pop_back_val();
    switch (Current.getOpcode()) {
    case ISD::FrameIndex:
      return false;
    case ISD::ADDRSPACECAST: {
      unsigned From = cast<AddrSpaceCastSDNode>(Current)->getSrcAddressSpace();
      if (From != MCS51::XData && From != MCS51::Default)
        return false;
      Worklist.push_back(Current.getOperand(0));
      break;
    }
    case ISD::ADD:
    case ISD::BITCAST:
      for (SDValue Operand : Current->ops())
        Worklist.push_back(Operand);
      break;
    default:
      break;
    }
  }
  return true;
}

// The default-address-space description of an XDATA operand, so that the
// generic lowering treats the intrinsic exactly like its AS0 equivalent.
static MachinePointerInfo onDefaultBus(const MachinePointerInfo &Info) {
  return MachinePointerInfo(MCS51::Default, Info.Offset);
}

static bool isXDataTransfer(SDValue Dst, SDValue Src,
                            const MachinePointerInfo &DstPtrInfo,
                            const MachinePointerInfo &SrcPtrInfo) {
  return (DstPtrInfo.getAddrSpace() == MCS51::XData ||
          SrcPtrInfo.getAddrSpace() == MCS51::XData) &&
         isOnXDataBus(Dst, DstPtrInfo) && isOnXDataBus(Src, SrcPtrInfo);
}

static SDValue emitXDataMemcpy(SelectionDAG &DAG, const SDLoc &DL,
                               SDValue Chain, SDValue Dst, SDValue Src,
                               SDValue Size, Align DstAlign, Align SrcAlign,
                               bool IsVolatile, bool AlwaysInline,
                               const MachinePointerInfo &DstPtrInfo,
                               const MachinePointerInfo &SrcPtrInfo) {
  if (AlwaysInline || !isXDataTransfer(Dst, Src, DstPtrInfo, SrcPtrInfo))
    return SDValue();
  return DAG.getMemcpy(Chain, DL, Dst, Src, Size, DstAlign, SrcAlign,
                       IsVolatile, /*AlwaysInline=*/false, /*CI=*/nullptr,
                       std::nullopt, onDefaultBus(DstPtrInfo),
                       onDefaultBus(SrcPtrInfo));
}

SDValue MCS51SelectionDAGInfo::EmitTargetCodeForMemcpy(
    SelectionDAG &DAG, const SDLoc &DL, SDValue Chain, SDValue Dst,
    SDValue Src, SDValue Size, Align DstAlign, Align SrcAlign,
    bool IsVolatile, bool AlwaysInline, MachinePointerInfo DstPtrInfo,
    MachinePointerInfo SrcPtrInfo) const {
  auto *ConstantSize = dyn_cast<ConstantSDNode>(Size);
  if (!ConstantSize)
    return emitXDataMemcpy(DAG, DL, Chain, Dst, Src, Size, DstAlign, SrcAlign,
                           IsVolatile, AlwaysInline, DstPtrInfo, SrcPtrInfo);

  uint64_t Count = ConstantSize->getZExtValue();
  bool NeedsAddressSpaceAwareCopy =
      usesAddressSpaceAwareMemcpy(SrcPtrInfo.getAddrSpace()) ||
      usesAddressSpaceAwareMemcpy(DstPtrInfo.getAddrSpace());

  // Clang represents an MCS-51 stack object as an alloca in AS0 and casts its
  // pointer to IDATA for ABI uses. LLVM's generic memcpy lowering casts that
  // pointer back to AS0; recover the actual bus before constructing memory
  // operations, or the copy would incorrectly use MOVX instead of @Ri.
  if (Dst.getOpcode() == ISD::ADDRSPACECAST) {
    auto *Cast = cast<AddrSpaceCastSDNode>(Dst);
    if (usesAddressSpaceAwareMemcpy(Cast->getSrcAddressSpace())) {
      NeedsAddressSpaceAwareCopy = true;
      Dst = Dst.getOperand(0);
      DstPtrInfo = MachinePointerInfo(Cast->getSrcAddressSpace());
    }
  }
  if (Src.getOpcode() == ISD::ADDRSPACECAST) {
    auto *Cast = cast<AddrSpaceCastSDNode>(Src);
    if (usesAddressSpaceAwareMemcpy(Cast->getSrcAddressSpace())) {
      NeedsAddressSpaceAwareCopy = true;
      Src = Src.getOperand(0);
      SrcPtrInfo = MachinePointerInfo(Cast->getSrcAddressSpace());
    }
  }
  bool HasStackObject = containsFrameIndex(Dst) || containsFrameIndex(Src);
  if (!AlwaysInline && !NeedsAddressSpaceAwareCopy && !HasStackObject)
    return emitXDataMemcpy(DAG, DL, Chain, Dst, Src, Size, DstAlign, SrcAlign,
                           IsVolatile, AlwaysInline, DstPtrInfo, SrcPtrInfo);

  MachineMemOperand::Flags Flags =
      IsVolatile ? MachineMemOperand::MOVolatile : MachineMemOperand::MONone;
  for (uint64_t Offset = 0; Offset < Count; ++Offset) {
    SDValue SrcOffset = DAG.getObjectPtrOffset(
        DL, Src, TypeSize::getFixed(Offset));
    SDValue DstOffset = DAG.getObjectPtrOffset(
        DL, Dst, TypeSize::getFixed(Offset));
    SDValue Load = DAG.getLoad(MVT::i8, DL, Chain, SrcOffset,
                               SrcPtrInfo.getWithOffset(Offset), Align(1),
                               Flags);
    Chain = DAG.getStore(Load.getValue(1), DL, Load, DstOffset,
                         DstPtrInfo.getWithOffset(Offset), Align(1), Flags);
  }
  return Chain;
}

SDValue MCS51SelectionDAGInfo::EmitTargetCodeForMemmove(
    SelectionDAG &DAG, const SDLoc &DL, SDValue Chain, SDValue Dst,
    SDValue Src, SDValue Size, Align DstAlign, Align SrcAlign,
    bool IsVolatile, MachinePointerInfo DstPtrInfo,
    MachinePointerInfo SrcPtrInfo) const {
  if (!isXDataTransfer(Dst, Src, DstPtrInfo, SrcPtrInfo))
    return SDValue();
  return DAG.getMemmove(Chain, DL, Dst, Src, Size, DstAlign, SrcAlign,
                        IsVolatile, /*CI=*/nullptr, std::nullopt,
                        onDefaultBus(DstPtrInfo), onDefaultBus(SrcPtrInfo));
}

// The runtime implements the C prototype
//   void *memset(void *Destination, int Value, size_t Count);
// where int and size_t are 16 bits wide. Under the MCS-51 calling convention
// the i16 Value is the second 16-bit argument (IP1) and Count the third (IP2).
// The generic libcall passes Value with the intrinsic's i8 type, which the
// calling convention assigns to R7, so the caller and the runtime disagree on
// both Value and Count. Pass Value as a C int instead, like a direct C call.
static SDValue emitMemsetLibcall(SelectionDAG &DAG, const SDLoc &DL,
                                 SDValue Chain, SDValue Dst, SDValue Value,
                                 SDValue Size) {
  RTLIB::LibcallImpl MemsetImpl =
      DAG.getLibcalls().getLibcallImpl(RTLIB::MEMSET);
  if (MemsetImpl == RTLIB::Unsupported)
    return SDValue();

  LLVMContext &Ctx = *DAG.getContext();
  const DataLayout &Layout = DAG.getDataLayout();
  const TargetLowering &TLI = DAG.getTargetLoweringInfo();
  EVT IntVT = EVT::getIntegerVT(Ctx, DAG.getLibInfo().getIntSize());

  TargetLowering::ArgListTy Args;
  Args.emplace_back(Dst, PointerType::getUnqual(Ctx));
  Args.emplace_back(DAG.getZExtOrTrunc(Value, DL, IntVT),
                    IntVT.getTypeForEVT(Ctx));
  Args.emplace_back(Size, Layout.getIntPtrType(Ctx));

  TargetLowering::CallLoweringInfo CLI(DAG);
  CLI.setDebugLoc(DL)
      .setChain(Chain)
      .setLibCallee(DAG.getLibcalls().getLibcallImplCallingConv(MemsetImpl),
                    Dst.getValueType().getTypeForEVT(Ctx),
                    DAG.getExternalSymbol(MemsetImpl, TLI.getPointerTy(Layout)),
                    std::move(Args))
      .setDiscardResult();
  return TLI.LowerCallTo(CLI).second;
}

SDValue MCS51SelectionDAGInfo::EmitTargetCodeForMemset(
    SelectionDAG &DAG, const SDLoc &DL, SDValue Chain, SDValue Dst,
    SDValue Value, SDValue Size, Align Alignment, bool IsVolatile,
    bool AlwaysInline, MachinePointerInfo DstPtrInfo) const {
  if (AlwaysInline || !isOnXDataBus(Dst, DstPtrInfo))
    return SDValue();
  return emitMemsetLibcall(DAG, DL, Chain, Dst, Value, Size);
}
