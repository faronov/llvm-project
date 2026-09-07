#!/usr/bin/env bash
set -euo pipefail

cd "${GITHUB_WORKSPACE:?}"
: "${HOST_TRIPLE:?}" "${RUST_SHA:?}" "${LLVM_BASELINE_SHA:?}" "${GITHUB_SHA:?}"
test "$HOST_TRIPLE" = x86_64-unknown-linux-gnu
test "$(git -C rust rev-parse HEAD)" = "$RUST_SHA"
mkdir -p rust-evidence rust-artifact standalone-output
llvm_bin="$GITHUB_WORKSPACE/llvm-toolchain/bin"
rust_root="$GITHUB_WORKSPACE/rust"

git -C rust submodule update --init --depth 1 src/tools/cargo library/backtrace

# Cargo's two build jobs may both link. Serialize host links independently of
# compilation, and bound lld's own threads. TC32 target links do not use this.
cat > "$GITHUB_WORKSPACE/tc32-host-linker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec flock "${GITHUB_WORKSPACE:?}/tc32-host-link.lock" \
  "$GITHUB_WORKSPACE/llvm-toolchain/bin/clang" \
  --target=x86_64-unknown-linux-gnu \
  "-fuse-ld=$GITHUB_WORKSPACE/llvm-toolchain/bin/ld.lld" \
  -Wl,--threads=2 "$@"
EOF
chmod +x "$GITHUB_WORKSPACE/tc32-host-linker"
command -v flock

cat > rust/bootstrap.toml <<EOF
change-id = "ignore"

[llvm]
download-ci-llvm = false
link-shared = false

[build]
build = "$HOST_TRIPLE"
host = ["$HOST_TRIPLE"]
target = ["$HOST_TRIPLE", "tc32-unknown-none-elf"]
jobs = 2
docs = false

[rust]
download-rustc = false
llvm-tools = false
lld = false
channel = "dev"
incremental = false
debuginfo-level = 0
lto = "off"
codegen-units = 8
codegen-units-std = 1

[target.$HOST_TRIPLE]
llvm-config = "$llvm_bin/llvm-config"
llvm-filecheck = "$llvm_bin/FileCheck"
llvm-has-rust-patches = false
linker = "$GITHUB_WORKSPACE/tc32-host-linker"
default-linker-linux-override = "off"
EOF
cp rust/bootstrap.toml rust-evidence/
cp rust/src/stage0 rust-evidence/stage0-manifest.txt
{
  echo "rust_source_sha=$RUST_SHA"
  echo "llvm_source_sha=$GITHUB_SHA"
  echo "llvm_baseline_sha=$LLVM_BASELINE_SHA"
  echo "workflow_source_sha=$GITHUB_SHA"
  echo "host=$HOST_TRIPLE"
  echo "rust_compile_jobs=2"
  echo "rust_host_link_jobs=1"
  echo "rust_lld_threads=2"
  echo "snapshot=Rust src/stage0 (not the runner's rustup default)"
  git -C rust submodule status
  df -h .
} | tee rust-evidence/provenance.txt

(
  cd rust
  python3 x.py build --stage 2 --jobs 2 \
    compiler/rustc src/tools/cargo library/std --target tc32-unknown-none-elf
) 2>&1 | tee rust-evidence/build.log

# Use the snapshot downloaded and checksum-checked by pinned Rust bootstrap.
# The runner's default rustup toolchain is unrelated and must not leak in.
snapshot_rustc="$rust_root/build/$HOST_TRIPLE/stage0/bin/rustc"
test -x "$snapshot_rustc"
snapshot_sysroot="$("$snapshot_rustc" --print sysroot)"
{
  "$snapshot_rustc" -vV
  "$rust_root/build/$HOST_TRIPLE/stage2/bin/rustc" -vV
  "$llvm_bin/clang" --version
  "$llvm_bin/llvm-config" --version --components
} | tee rust-evidence/compiler-versions.txt
HOST_TRIPLE="$HOST_TRIPLE" \
RUST_BUILD_DIR="$rust_root/build" \
LLVM_TOOLCHAIN_DIR="$GITHUB_WORKSPACE/llvm-toolchain" \
TOOLCHAIN_OUTPUT_DIR="$GITHUB_WORKSPACE/standalone-output" \
RUST_SOURCE_DIR="$rust_root" \
BOOTSTRAP_RUSTC="$rust_root/build/bootstrap/debug/rustc" \
SNAPSHOT_RUSTC="$snapshot_rustc" \
SNAPSHOT_SYSROOT="$snapshot_sysroot" \
RUST_OBJCOPY_SOURCE="$llvm_bin/llvm-objcopy" \
  bash rust/src/ci/scripts/package-stage2-tc32-toolchain.sh \
  2>&1 | tee rust-evidence/package.log

package_name="tc32-stage2-experimental-${GITHUB_SHA:0:12}-$HOST_TRIPLE"
rm standalone-output/tc32-stage2
mv "standalone-output/tc32-stage2-$HOST_TRIPLE" "standalone-output/$package_name"
package="$GITHUB_WORKSPACE/standalone-output/$package_name"
# git archive in the pinned packager does not materialize submodules. The
# library/backtrace sources are needed for a complete host build-std source tree.
test "$(git -C rust/library/backtrace rev-parse HEAD)" = \
  "$(git -C rust rev-parse HEAD:library/backtrace)"
for sources in src/rust rustc-src/rust; do
  destination="$package/lib/rustlib/$sources/library/backtrace"
  mkdir -p "$destination"
  git -C rust/library/backtrace archive HEAD | tar -xf - -C "$destination"
done
cp rust-evidence/provenance.txt "$package/TC32-EXPERIMENT.txt"
cp rust-evidence/llvm-SHA256SUMS "$package/LLVM-SHA256SUMS"
cat > "$package/EXPERIMENTAL.txt" <<EOF
Experimental compiler qualification only; not a production replacement.
LLVM: $GITHUB_SHA
LLVM baseline: $LLVM_BASELINE_SHA
Rust: $RUST_SHA
Target: tc32-unknown-none-elf; host: $HOST_TRIPLE
Firmware size, disassembly, emulator/hardware and network qualification remain required.
Extract into a NEW directory. Do not overwrite or relink an existing production toolchain.
EOF
"$package/bin/rustc" -vV | tee rust-evidence/packaged-rustc.txt
"$package/bin/cargo" -V | tee rust-evidence/packaged-cargo.txt
test -x "$package/lib/rustlib/$HOST_TRIPLE/bin/rust-objcopy"
test -f "$package/lib/rustlib/src/rust/library/core/src/lib.rs"
test -f "$package/lib/rustlib/rustc-src/rust/library/core/src/lib.rs"
test ! -L "$package/lib/rustlib/src/rust"
test ! -L "$package/lib/rustlib/rustc-src/rust"
compgen -G "$package/lib/rustlib/tc32-unknown-none-elf/lib/libcore-*.rlib" > /dev/null
compgen -G "$package/lib/rustlib/tc32-unknown-none-elf/lib/libcompiler_builtins-*.rlib" > /dev/null
tar -C standalone-output -czf \
  rust-artifact/tc32-experimental-rust-toolchain-linux-amd64.tar.gz "$package_name"
(
  cd rust-artifact
  sha256sum tc32-experimental-rust-toolchain-linux-amd64.tar.gz > SHA256SUMS
)
cp rust-artifact/SHA256SUMS rust-evidence/rust-SHA256SUMS
