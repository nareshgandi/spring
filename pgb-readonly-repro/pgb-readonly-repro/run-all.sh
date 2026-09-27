#!/usr/bin/env bash
# Runs the baseline and every fix, then prints a summary.
# Usage: ./run-all.sh [spring|jdbc|explicit] [seconds]
cd "$(dirname "$0")"
MODE="${1:-spring}"
SECS="${2:-20}"
mkdir -p results
SUMMARY=()

run_case() {  # id  fix  ro_mode  description
  local id=$1 fix=$2 ro=$3 desc=$4 log="results/$MODE-$1.log" line
  FIX=$fix RO_MODE=$ro ./run.sh "$MODE" "$SECS" 2>&1 | tee "$log"
  line=$(grep '^RESULT' "$log" | tail -1)
  SUMMARY+=("$(printf '%-48s %s' "$desc" "${line:-FAILED TO RUN (see $log)}")")
  echo
}

run_case baseline none  always "Baseline (no fix)"
run_case track    track always "Fix A: track_extra_parameters (PgBouncer)"
run_case reset    reset always "Fix B: RESET after every txn (PgBouncer)"
if [ "$MODE" = "spring" ] || [ "$MODE" = "jdbc" ]; then
  run_case driver none transaction "Fix C: readOnlyMode=transaction (JDBC URL)"
fi

echo "================ SUMMARY (mode=$MODE, ${SECS}s each) ================"
printf '%s\n' "${SUMMARY[@]}"
