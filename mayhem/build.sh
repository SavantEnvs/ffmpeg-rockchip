#!/usr/bin/env bash
#
# mayhem/build.sh — build the FFmpeg fuzz targets (upstream's tools/target_*_fuzzer.c) with ASan+UBSan,
# plus a clean, normally-flagged ffmpeg build that mayhem/test.sh (FATE) runs.
#
# Runs inside the commit image as `mayhem` in /mayhem. Re-runnable and network-free: FFmpeg has no
# fetched dependencies (--disable-autodetect; only the in-image zlib is enabled).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# Targets: <binary name> = make target under tools/ (or top-level for the codec/demuxer-specific ones).
# FFmpeg's own Makefile derives each decoder/encoder/demuxer/bsf variant from the stem of the target name.
TARGETS="
target_dec_h264_fuzzer
target_dec_hevc_fuzzer
target_dec_mjpeg_fuzzer
target_dec_png_fuzzer
target_dem_fuzzer
target_dem_matroska_fuzzer
target_dem_mov_fuzzer
target_bsf_h264_mp4toannexb_fuzzer
target_sws_fuzzer
target_swr_fuzzer
"

COMMON_CONF="--disable-asm --disable-autodetect --enable-zlib --disable-doc --disable-debug --disable-stripping"

# ---------------------------------------------------------------- 1) sanitized fuzz build
FUZZ_DIR="$SRC/mayhem/build-fuzz"
mkdir -p "$FUZZ_DIR"
cd "$FUZZ_DIR"; mkdir -p tools
if [ ! -f config.h ]; then
  # LSan is irrelevant at configure time (its probes leak by design); this is not a runtime option for Mayhem.
  ASAN_OPTIONS=detect_leaks=0 "$SRC/configure" \
    --cc="$CC" --cxx="$CXX" --ld="$CC" \
    $COMMON_CONF --enable-ossfuzz \
    --extra-cflags="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS" \
    --extra-ldflags="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link"
fi

# Leak detection off at build time (ASan/UBSan stay on), and the run-once driver for the -standalone reproducers.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.c" -o "$FUZZ_DIR/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_DIR/standalone_main.o"

path_of() { echo "tools/$1"; }

# Make the fuzz-target variants (first pass links libFuzzer).
for t in $TARGETS; do
  make -j"$MAYHEM_JOBS" LIBFUZZER_PATH="$FUZZ_DIR/lsan_off.o $LIB_FUZZING_ENGINE" "$(path_of "$t")"
  cp -f "$(path_of "$t")" "$SRC/$t"
  rm -f "$(path_of "$t")"
  make LIBFUZZER_PATH="$FUZZ_DIR/lsan_off.o $FUZZ_DIR/standalone_main.o" "$(path_of "$t")"
  cp -f "$(path_of "$t")" "$SRC/$t-standalone"
  rm -f "$(path_of "$t")"
done

# ---------------------------------------------------------------- 2) clean oracle build (project's NORMAL flags)
cd "$SRC"
TEST_DIR="$SRC/mayhem/build-test"
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"; mkdir -p tools
if [ ! -f config.h ]; then
  env -u CFLAGS -u LDFLAGS "$SRC/configure" --cc="$CC" --cxx="$CXX" $COMMON_CONF \
    --extra-cflags="$COVERAGE_FLAGS" --extra-ldflags="$COVERAGE_FLAGS"
fi
make -j"$MAYHEM_JOBS" ffmpeg ffprobe
# Helper programs FATE runs (generators, psnr/ssim/base64 comparators), built here so test.sh never compiles.
make -j"$MAYHEM_JOBS" tests/base64 tests/tiny_psnr tests/tiny_ssim tests/audiomatch tests/videogen tests/audiogen tests/rotozoom
