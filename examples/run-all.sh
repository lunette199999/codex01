#!/usr/bin/env bash
# Regenerates every frame dump in examples/output/.
#
#   ./examples/run-all.sh            # csv into examples/output
#   ./examples/run-all.sh jsonl      # jsonl instead
set -euo pipefail
cd "$(dirname "$0")/.."
format="${1:-csv}"
mkdir -p examples/output
swift build -c release --product choreo-demo >/dev/null
binary="$(swift build -c release --show-bin-path)/choreo-demo"

for scenario in greeting interrupt reverse cancel speech masked aperture idle-off hide-resume time-gap queue; do
    "$binary" --scenario "$scenario" --format "$format" > "examples/output/$scenario.$format"
    printf '  %-12s -> examples/output/%s.%s\n' "$scenario" "$scenario" "$format"
done

# The idle scenario runs for a minute; its point is that the same seed replays
# exactly, so only the sequence starts and stops are kept.
"$binary" --scenario ambient --format csv \
    | awk -F, 'NR==1 || $NF != ""' > "examples/output/ambient-notices.csv"
printf '  %-12s -> examples/output/ambient-notices.csv\n' "ambient"
