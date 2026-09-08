#!/usr/bin/env bash
set -euo pipefail

cd "${GITHUB_WORKSPACE:?}"
: "${GITHUB_SHA:?}" "${HOST_TRIPLE:?}" "${RUST_SHA:?}" "${LLVM_BASELINE_SHA:?}"
mkdir -p qualification/smoke/src relocated-toolchain
(cd rust-artifact && sha256sum -c SHA256SUMS) | tee qualification/checksums.txt
tar -xzf rust-artifact/tc32-experimental-rust-toolchain-linux-amd64.tar.gz \
  -C relocated-toolchain
package="$GITHUB_WORKSPACE/relocated-toolchain/tc32-stage2-experimental-${GITHUB_SHA:0:12}-$HOST_TRIPLE"
grep -Fx "llvm_source_sha=$GITHUB_SHA" "$package/TC32-EXPERIMENT.txt"
grep -Fx "rust_source_sha=$RUST_SHA" "$package/TC32-EXPERIMENT.txt"
grep -Fx "llvm_baseline_sha=$LLVM_BASELINE_SHA" "$package/TC32-EXPERIMENT.txt"
cp "$package/TC32-EXPERIMENT.txt" qualification/
cp rust-artifact/SHA256SUMS qualification/rust-SHA256SUMS
{
  "$package/bin/rustc" -vV
  "$package/bin/cargo" -V
  "$package/llvm/bin/clang" --version
  "$package/lib/rustlib/$HOST_TRIPLE/bin/rust-objcopy" --version
} | tee qualification/compiler-versions.txt
"$package/bin/rustc" --print target-list | grep -Fx tc32-unknown-none-elf
"$package/bin/rustc" --print cfg --target tc32-unknown-none-elf \
  | tee qualification/tc32-cfg.txt
grep -Fx 'target_arch="tc32"' qualification/tc32-cfg.txt
test ! -L "$package/lib/rustlib/src/rust"
test ! -L "$package/lib/rustlib/rustc-src/rust"

cat > qualification/smoke/Cargo.toml <<'EOF'
[package]
name = "tc32-experimental-smoke"
version = "0.0.0"
edition = "2021"

[profile.dev]
panic = "abort"

[profile.release]
panic = "abort"
opt-level = "s"
EOF
cat > qualification/smoke/src/main.rs <<'EOF'
#![cfg_attr(target_arch = "tc32", no_std)]
#![cfg_attr(target_arch = "tc32", no_main)]

#[repr(C, packed)]
struct Packed {
    tag: u8,
    word: u32,
}

#[inline(never)]
fn snapshot() -> u8 {
    let mut p = Packed { tag: 1, word: 0x44332211 };
    let saved = core::hint::black_box(&p).word;
    core::hint::black_box(&mut p).word = 0;
    (saved >> 16) as u8
}

#[cfg(not(target_arch = "tc32"))]
fn main() {
    assert_eq!(snapshot(), 0x33);
}

#[cfg(target_arch = "tc32")]
#[no_mangle]
pub extern "C" fn _start() -> ! {
    core::hint::black_box(snapshot());
    loop { core::hint::spin_loop(); }
}

#[cfg(target_arch = "tc32")]
#[panic_handler]
fn panic(_: &core::panic::PanicInfo<'_>) -> ! {
    loop { core::hint::spin_loop(); }
}
EOF
cat > qualification/smoke/link.ld <<'EOF'
ENTRY(_start)
SECTIONS {
  . = 0;
  .text : { *(.text*) }
  .rodata : { *(.rodata*) }
  .data : { *(.data*) }
  .bss : { *(.bss*) *(COMMON) }
  /DISCARD/ : { *(.comment) *(.note*) *(.ARM.attributes) }
}
EOF
# A new runner has neither the Rust build tree nor the LLVM installation prefix.
# The offline build exercises the packaged cargo/rustc wrappers and target rlibs.
unset RUSTC RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER RUSTFLAGS CARGO_ENCODED_RUSTFLAGS
unset TC32_LLVM_BIN CARGO_TARGET_TC32_UNKNOWN_NONE_ELF_LINKER
export CARGO_HOME="$GITHUB_WORKSPACE/qualification/cargo-home"
export CARGO_TARGET_DIR="$GITHUB_WORKSPACE/qualification/target"
manifest="$GITHUB_WORKSPACE/qualification/smoke/Cargo.toml"
"$package/bin/cargo" run --offline --manifest-path "$manifest" \
  --target "$HOST_TRIPLE" 2>&1 | tee qualification/host-smoke.log
for profile in dev release; do
  "$package/bin/cargo" rustc --offline --manifest-path "$manifest" \
    --target tc32-unknown-none-elf --profile "$profile" -- \
    -C llvm-args=-enable-tail-merge=false \
    -C "link-arg=-T$GITHUB_WORKSPACE/qualification/smoke/link.ld" \
    -C link-arg=--gc-sections \
    -C link-arg=-z -C link-arg=max-page-size=0x8000 \
    -C link-arg=-z -C link-arg=common-page-size=0x8000 \
    2>&1 | tee "qualification/tc32-$profile.log"
  output_profile=$profile
  if [[ $profile == dev ]]; then output_profile=debug; fi
  elf="$CARGO_TARGET_DIR/tc32-unknown-none-elf/$output_profile/tc32-experimental-smoke"
  cp "$elf" "qualification/tc32-$profile.elf"
  "$package/llvm/bin/llvm-readobj" --file-headers "$elf" \
    | tee "qualification/tc32-$profile-header.txt"
  grep -E 'Machine:.*(8800|TC32)' "qualification/tc32-$profile-header.txt"
  "$package/llvm/bin/llvm-objdump" -d "$elf" > "qualification/tc32-$profile.s"
  "$package/llvm/bin/llvm-size" "$elf" | tee "qualification/tc32-$profile-size.txt"
  "$package/llvm/bin/llvm-objcopy" -O binary "$elf" "qualification/tc32-$profile.bin"
done

baseline=llvm-evidence/tc32-experimental-llvm-evidence-baseline-linux-amd64
candidate=llvm-evidence/tc32-experimental-llvm-evidence-candidate-linux-amd64
grep -Fx EXPECTED_BASELINE_FAILURE "$baseline/snapshot-result.txt"
grep -Fx CANDIDATE_PASS "$candidate/snapshot-result.txt"
grep -Fx EXPECTED_BASELINE_SEMANTIC_FAILURE "$baseline/semantic-result.txt"
grep -Fx CANDIDATE_SEMANTIC_PASS "$candidate/semantic-result.txt"
grep -Fx EXPECTED_BASELINE_CONSTANT_FOLD_FAILURE "$baseline/constant-fold-result.txt"
grep -Fx CANDIDATE_CONSTANT_FOLD_PASS "$candidate/constant-fold-result.txt"
grep -Fx EXPECTED_BASELINE_IMMEDIATE_EXPAND_CRASH "$baseline/codegen-result.txt"
grep -Fx CANDIDATE_CODEGEN_PASS "$candidate/codegen-result.txt"
grep -Fx BASELINE_LIT_PINNED_FAILURES_CONFIRMED "$baseline/lit-result.txt"
grep -Fx CANDIDATE_LIT_PASS "$candidate/lit-result.txt"
cmp "$baseline/snapshot.input.ll" "$candidate/snapshot.input.ll"
cmp "$baseline/snapshot-semantics.input.ll" "$candidate/snapshot-semantics.input.ll"
cmp "$baseline/immediate-expand.input.mir" "$candidate/immediate-expand.input.mir"
cp "$baseline/lit-known-failures.txt" qualification/baseline-known-codegen-crashes.txt
cp "$baseline/lit-classification.json" qualification/baseline-lit-classification.json
cp "$candidate/lit-classification.json" qualification/candidate-lit-classification.json
for diagnostic in tc32-atomic-error.ll tc32-ldrex-error.ll; do
  cp "$baseline/$diagnostic.control."* qualification/
done
cp "$candidate/snapshot.s" qualification/snapshot.candidate.s
for output in snapshot.opt.ll snapshot-semantics.opt.ll snapshot-semantics.folded.ll; do
  status=0
  diff -u "$baseline/$output" "$candidate/$output" \
    > "qualification/$output.diff" || status=$?
  if [[ $status -gt 1 ]]; then exit "$status"; fi
done
cat > qualification/result.txt <<EOF
PASS: pinned baseline fails both new snapshot regressions as expected; candidate passes.
PASS: untouched IR folds to success; TC32-transformed IR folds to baseline failure/candidate success.
PASS: baseline/candidate TC32-transformed IR semantic negative/positive controls on x86_64.
PASS: candidate immediate-expansion regression, TC32 lowering and full selected lit coverage.
BASELINE LIMITATION: the pristine assertions-on baseline has 16 exact PASS outcomes and 39 narrowly matched failures, not successful TC32 codegen.
BASELINE LIMITATION: 37 lit-visible crashes match immediate-expansion or constant-island assertions; two diagnostic failures additionally require separately captured exact immediate-expansion crashes.
PASS: no unknown, missing or skipped selected results; all nine neighboring ARM tests and the ARM immediate-expansion control pass in both builds.
PASS: relocated standalone package, native host execution, TC32 O0/Os compile and link (tail merging disabled).
NOT QUALIFIED: real firmware, TC32 runtime/emulation, hardware or network behavior.
No production toolchain was installed, replaced, registered or relinked.
EOF
tee -a "$GITHUB_STEP_SUMMARY" < qualification/result.txt
# Keep diagnostics and resulting firmware, not Cargo's disposable build cache.
rm -rf qualification/target qualification/cargo-home
