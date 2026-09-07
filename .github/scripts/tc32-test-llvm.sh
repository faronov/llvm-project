#!/usr/bin/env bash
set -euo pipefail

if [[ $# != 5 || ( $1 != baseline && $1 != candidate ) ]]; then
  echo "usage: $0 baseline|candidate LLVM_SOURCE LLVM_BUILD EXPERIMENT_SOURCE EVIDENCE" >&2
  exit 2
fi
variant=$1
source_dir=$2
build_dir=$3
experiment_dir=$4
evidence=$5
arm_tests="$source_dir/llvm/test/CodeGen/ARM"
snapshot="$experiment_dir/llvm/test/CodeGen/ARM/tc32-packed-byte-load-snapshot.ll"
mkdir -p "$evidence"
test -s "$snapshot"
cp "$snapshot" "$evidence/snapshot.input.ll"

# Keep the optimizer exit status separate: a crash is not an expected regression.
"$build_dir/bin/opt" -mtriple=tc32-unknown-none-elf \
  -passes='default<O0>' -verify-each -S \
  < "$snapshot" > "$evidence/snapshot.opt.ll"
check_status=0
"$build_dir/bin/FileCheck" "$snapshot" \
  < "$evidence/snapshot.opt.ll" \
  > "$evidence/snapshot-filecheck.log" 2>&1 || check_status=$?
cat "$evidence/snapshot-filecheck.log"
if [[ $variant == baseline ]]; then
  if [[ $check_status != 1 ]]; then
    echo "Baseline must compile successfully but fail the new FileCheck regression (got $check_status)." >&2
    exit 1
  fi
  echo "EXPECTED_BASELINE_FAILURE" > "$evidence/snapshot-result.txt"
else
  if [[ $check_status != 0 ]]; then
    echo "Candidate snapshot regression failed (FileCheck exit $check_status)." >&2
    exit 1
  fi
  echo "CANDIDATE_PASS" > "$evidence/snapshot-result.txt"
fi
# The untouched program must fold to success in both compilers. Only the
# baseline's TC32-transformed program may fold to the known failure result.
semantics="$experiment_dir/llvm/test/CodeGen/ARM/tc32-packed-byte-load-snapshot-semantics.ll"
test -s "$semantics"
cp "$semantics" "$evidence/snapshot-semantics.input.ll"
fold_passes='cgscc(inline),function(sroa,instcombine)'
"$build_dir/bin/opt" -passes="$fold_passes" -verify-each -S \
  < "$semantics" > "$evidence/snapshot-semantics.reference.ll"
"$build_dir/bin/FileCheck" "$semantics" \
  < "$evidence/snapshot-semantics.reference.ll" \
  2>&1 | tee "$evidence/snapshot-semantics-reference-filecheck.log"
"$build_dir/bin/opt" -mtriple=tc32-unknown-none-elf \
  -passes='default<O0>' -verify-each -S \
  < "$semantics" > "$evidence/snapshot-semantics.opt.ll"
"$build_dir/bin/opt" -passes="$fold_passes" -verify-each -S \
  < "$evidence/snapshot-semantics.opt.ll" > "$evidence/snapshot-semantics.folded.ll"
check_status=0
"$build_dir/bin/FileCheck" "$semantics" \
  < "$evidence/snapshot-semantics.folded.ll" \
  > "$evidence/snapshot-semantics-filecheck.log" 2>&1 || check_status=$?
cat "$evidence/snapshot-semantics-filecheck.log"
if [[ $variant == baseline && $check_status == 1 ]]; then
  "$build_dir/bin/FileCheck" - \
    --input-file="$evidence/snapshot-semantics.folded.ll" <<'EOF'
; CHECK-LABEL: define i32 @main(
; CHECK: ret i32 1
EOF
  echo "EXPECTED_BASELINE_CONSTANT_FOLD_FAILURE" > "$evidence/constant-fold-result.txt"
elif [[ $variant == candidate && $check_status == 0 ]]; then
  echo "CANDIDATE_CONSTANT_FOLD_PASS" > "$evidence/constant-fold-result.txt"
else
  echo "Unexpected $variant constant-folding regression result: $check_status" >&2
  exit 1
fi

# Execute the transformed load/store/call semantics on little-endian x86_64.
# This tests the TC32 IR pass output, not TC32 instruction execution. Extract
# only these functions so unrelated atomic/unsupported-operation cases do not
# introduce host runtime dependencies.
"$build_dir/bin/llvm-extract" -S \
  --func=low_byte_before_store --func=high_byte_before_store \
  --func=byte_before_call --func=repeated_low_byte \
  --func=repeated_high_byte --func=two_bytes_before_call \
  "$evidence/snapshot.opt.ll" -o "$evidence/snapshot.semantic.ll"
cat > "$evidence/snapshot-harness.c" <<'EOF'
#include <stdio.h>
#include <string.h>

extern unsigned char low_byte_before_store(void *, unsigned char);
extern unsigned char high_byte_before_store(void *, unsigned char);
extern unsigned char byte_before_call(void *);
extern unsigned char repeated_low_byte(void *, unsigned char);
extern unsigned char repeated_high_byte(void *);
extern unsigned char two_bytes_before_call(void *);

void clobber(void *p) { memset(p, 0, 4); }

static unsigned check(const char *name, unsigned got, unsigned expected) {
  printf("%s: got=%02x expected=%02x\n", name, got, expected);
  return got != expected;
}

int main(void) {
  const unsigned char initial[] = {0x11, 0x22, 0x33, 0x44};
  unsigned char bytes[5];
  unsigned char *p = bytes + 1;
  unsigned failures = 0;
  memcpy(p, initial, 4);
  failures += check("low/store", low_byte_before_store(p, 0x5a), 0x11);
  memcpy(p, initial, 4);
  failures += check("high/store", high_byte_before_store(p, 0x5a), 0x33);
  memcpy(p, initial, 4);
  failures += check("high/call", byte_before_call(p), 0x44);
  memcpy(p, initial, 4);
  failures += check("repeated-low/store", repeated_low_byte(p, 0x5a), 0x22);
  memcpy(p, initial, 4);
  failures += check("repeated-high/call", repeated_high_byte(p), 0x44);
  memcpy(p, initial, 4);
  failures += check("two-bytes/call", two_bytes_before_call(p), 0x33);
  return failures ? 1 : 0;
}
EOF
"$build_dir/bin/clang" --target=x86_64-unknown-linux-gnu -O0 \
  -Wno-override-module "$evidence/snapshot.semantic.ll" \
  "$evidence/snapshot-harness.c" -o "$evidence/snapshot-host"
semantic_status=0
"$evidence/snapshot-host" > "$evidence/snapshot-semantics.log" 2>&1 || semantic_status=$?
cat "$evidence/snapshot-semantics.log"
if [[ $variant == baseline && $semantic_status == 1 ]]; then
  echo "EXPECTED_BASELINE_SEMANTIC_FAILURE" > "$evidence/semantic-result.txt"
elif [[ $variant == candidate && $semantic_status == 0 ]]; then
  echo "CANDIDATE_SEMANTIC_PASS" > "$evidence/semantic-result.txt"
else
  echo "Unexpected $variant semantic control result: $semantic_status" >&2
  exit 1
fi

# Keep the baseline pristine and assertions enabled. Its separate immediate
# expansion bug is a crash control, never evidence of the snapshot wrong-code.
expect_immediate_expand_crash() {
  local name=$1
  shift
  local log="$evidence/$name.log"
  if ! "$build_dir/bin/not" --crash "$@" > "$log" 2>&1; then
    cat "$log"
    echo "Expected the pinned baseline's immediate-expansion assertion: $name" >&2
    return 1
  fi
  cat "$log"
  grep -F 'Assertion `Index < this->size() && "Invalid index!"' "$log"
  grep -F "Running pass 'TC32 immediate ALU expand'" "$log"
}

immediate="$experiment_dir/llvm/test/CodeGen/ARM/tc32-immediate-expand.mir"
test -s "$immediate"
cp "$immediate" "$evidence/immediate-expand.input.mir"
if [[ $variant == baseline ]]; then
  expect_immediate_expand_crash immediate-expand \
    "$build_dir/bin/llc" -mtriple=tc32-unknown-none-elf \
    -run-pass=tc32-immediate-expand -verify-machineinstrs "$immediate" -o /dev/null
  expect_immediate_expand_crash snapshot-codegen \
    "$build_dir/bin/llc" -mtriple=tc32-unknown-none-elf -O0 \
    -thread-model=single -verify-machineinstrs "$evidence/snapshot.opt.ll" -o /dev/null
  echo "EXPECTED_BASELINE_IMMEDIATE_EXPAND_CRASH" > "$evidence/codegen-result.txt"
else
  "$build_dir/bin/llc" -mtriple=tc32-unknown-none-elf \
    -run-pass=tc32-immediate-expand -verify-machineinstrs "$immediate" \
    -o "$evidence/immediate-expand.mir"
  "$build_dir/bin/FileCheck" "$immediate" < "$evidence/immediate-expand.mir"
  "$build_dir/bin/llc" -mtriple=tc32-unknown-none-elf -O0 \
    -thread-model=single -verify-machineinstrs \
    "$evidence/snapshot.opt.ll" -o "$evidence/snapshot.s"
  echo "CANDIDATE_CODEGEN_PASS" > "$evidence/codegen-result.txt"
fi
"$build_dir/bin/llc" -mtriple=thumbv6m-unknown-none-eabi \
  -run-pass=tc32-immediate-expand -verify-machineinstrs "$immediate" \
  -o "$evidence/immediate-expand.arm.mir"
"$build_dir/bin/FileCheck" "$immediate" --check-prefix=ARM \
  < "$evidence/immediate-expand.arm.mir"

# Each revision runs its own tests; only the controls above import regressions,
# from the same run's exact candidate checkout rather than an external URL.
tests=("$arm_tests"/tc32-*.ll "$arm_tests"/tc32-*.mir)
for neighbor in \
  legalize-unaligned-load.ll \
  unaligned_load_store.ll \
  unaligned_load_store_aeabi.ll \
  unaligned_load_store_vfp.ll \
  i64_volatile_load_store.ll \
  load-store-pair-volatile.ll \
  memcpy-const-vol-struct.ll \
  memcpy-inline.ll \
  memcpy-ldm-stm.ll; do
  tests+=("$arm_tests/$neighbor")
done
for test_file in "${tests[@]}"; do
  test -f "$test_file"
done
printf '%s\n' "${tests[@]}" > "$evidence/lit-selection.txt"
lit_status=0
python3 "$build_dir/bin/llvm-lit" -v -j 2 \
  --xunit-xml-output="$evidence/lit.xml" \
  -o "$evidence/lit.json" "${tests[@]}" > "$evidence/lit.log" 2>&1 || lit_status=$?
cat "$evidence/lit.log"
python3 - "$variant" "$lit_status" "$evidence" "${#tests[@]}" <<'PY'
import json
from pathlib import Path
import sys

variant, status, directory, count = sys.argv[1:]
status = int(status)
evidence = Path(directory)
if status not in (0, 1):
    sys.exit(f"llvm-lit failed to execute normally: {status}")
tests = json.loads((evidence / "lit.json").read_text())["tests"]
if len(tests) != int(count) or not any(t["code"] == "PASS" for t in tests):
    sys.exit("Incomplete or empty lit coverage")
known = []
for test in tests:
    if test["code"] in ("PASS", "XFAIL", "UNSUPPORTED"):
        continue
    output = test["output"]
    if (
        variant == "baseline"
        and test["code"] == "FAIL"
        and "CodeGen/ARM/tc32-" in test["name"]
        and 'Assertion `Index < this->size() && "Invalid index!"' in output
        and "Running pass 'TC32 immediate ALU expand'" in output
    ):
        known.append(test["name"])
    else:
        sys.exit(f"Unexpected lit result: {test['code']} {test['name']}")
if status != int(bool(known)):
    sys.exit(f"lit exit {status} disagrees with recorded results")
if variant == "baseline":
    if not known:
        sys.exit("Pinned baseline did not reproduce its known codegen failure")
    marker = "BASELINE_LIT_KNOWN_IMMEDIATE_EXPAND_FAILURES"
    (evidence / "lit-known-failures.txt").write_text("\n".join(known) + "\n")
else:
    marker = "CANDIDATE_LIT_PASS"
(evidence / "lit-result.txt").write_text(marker + "\n")
print(marker)
for name in known:
    print(f"KNOWN BASELINE CRASH: {name}")
PY
