#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) Build the library (static) with sanitizers + DWARF-3. No upstream fuzz targets / CLI here: the
#    harnesses are compiled below against the static lib so we control the engine and standalone driver.
#    Build type is left empty on purpose (the project's Release default would append -O3 -DNDEBUG after ours).
# Compilers come from the CC/CXX env, not -DCMAKE_*_COMPILER: an explicit -D that differs from the path cached by an
# earlier (ccache-masqueraded) configure makes cmake wipe the cache and drop the other -D options on re-run.
# fuzzer-no-link: coverage-instrument the library too (not just the harness TU) so Mayhem sees real edges.
LIB_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -O1 -DNDEBUG -fsanitize=fuzzer-no-link"
cmake -S "$SRC" -B "$SRC/build" -G Ninja -DCMAKE_BUILD_TYPE=None \
      -DCMAKE_C_FLAGS="$LIB_FLAGS" -DCMAKE_CXX_FLAGS="$LIB_FLAGS" \
      -DBUILD_SHARED_LIBS=OFF -DEXIV2_BUILD_EXIV2_COMMAND=OFF -DEXIV2_BUILD_UNIT_TESTS=OFF \
      -DEXIV2_BUILD_FUZZ_TESTS=OFF -DEXIV2_BUILD_SAMPLES=OFF -DEXIV2_ENABLE_WEBREADY=ON \
      -DEXIV2_ENABLE_CURL=OFF -DEXIV2_ENABLE_BMFF=ON -DEXIV2_ENABLE_PNG=ON -DEXIV2_ENABLE_NLS=OFF
cmake --build "$SRC/build" -j"$MAYHEM_JOBS"

# 2) Harnesses: each linked twice (libFuzzer engine + standalone run-once driver), plus the LSan-off hook.
LIBS=("$SRC/build/lib/libexiv2.a" -lexpat -lz -lbrotlidec -lbrotlicommon -linih -lINIReader)
INCS=(-I"$SRC/include" -I"$SRC/build" -I"$SRC/src" -I"$SRC/build/include")
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o /tmp/lsan_off.o
$CC  $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
for h in fuzz-read-print-write fuzz-read-write fuzz-preview; do
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -std=c++17 "${INCS[@]}" $LIB_FUZZING_ENGINE \
       "$SRC/fuzz/$h.cpp" /tmp/lsan_off.o "${LIBS[@]}" -o "/mayhem/$h"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -std=c++17 "${INCS[@]}" \
       "$SRC/fuzz/$h.cpp" /tmp/standalone_main.o /tmp/lsan_off.o "${LIBS[@]}" -o "/mayhem/$h-standalone"
done

# 3) Unit tests (gtest) with the project's NORMAL flags, in a separate build dir; test.sh only runs them.
cmake -S "$SRC" -B "$SRC/build-tests" -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
      -DBUILD_SHARED_LIBS=OFF -DEXIV2_BUILD_EXIV2_COMMAND=OFF -DEXIV2_BUILD_UNIT_TESTS=ON \
      -DEXIV2_BUILD_FUZZ_TESTS=OFF -DEXIV2_BUILD_SAMPLES=OFF -DEXIV2_ENABLE_WEBREADY=ON \
      -DEXIV2_ENABLE_CURL=OFF -DEXIV2_ENABLE_BMFF=ON -DEXIV2_ENABLE_PNG=ON -DEXIV2_ENABLE_NLS=OFF
cmake --build "$SRC/build-tests" -j"$MAYHEM_JOBS" --target unit_tests
