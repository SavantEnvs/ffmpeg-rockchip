#!/usr/bin/env bash
#
# mayhem/test.sh — RUN a self-contained subset of FFmpeg's own FATE suite (no external samples).
# FATE generates its inputs (audiogen/videogen/lavfi), runs the clean-built ffmpeg/ffprobe and diffs the
# output against golden files in tests/ref/fate/, so a neutered ffmpeg fails every test. Built by build.sh.
# exit 0 = pass. Emits a CTRF report (results.summary) to ${CTRF_REPORT:-$SRC/ctrf-report.json} and stdout.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC/mayhem/build-test"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


# Self-contained FATE tests: decode/encode round trips, muxers/demuxers, scaling/filters, ffprobe output.
TESTS="
fate-acodec-flac fate-acodec-alac fate-acodec-pcm-s16le fate-acodec-mp2
fate-filter-scale200 fate-filter-crop fate-filter-pad fate-filter-testsrc2-yuv420p fate-filter-volume
fate-lavf-mkv fate-lavf-mov fate-lavf-png fate-lavf-avi fate-lavf-jpg fate-lavf-ogg fate-lavf-nut
fate-ffprobe_json
"

[ -x ./ffmpeg ] && [ -x ./ffprobe ] && [ -x tests/tiny_psnr ] || { echo "ffmpeg/ffprobe/FATE helpers missing — build.sh did not build them" >&2; emit_ctrf "fate" 0 1 0; exit 1; }

passed=0; failed=0
for t in $TESTS; do
  if make "$t" >"/tmp/$t.log" 2>&1; then
    passed=$((passed+1)); echo "PASS $t"
  else
    failed=$((failed+1)); echo "FAIL $t"; tail -20 "/tmp/$t.log"
  fi
done
emit_ctrf "fate" "$passed" "$failed" 0
