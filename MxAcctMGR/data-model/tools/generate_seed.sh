#!/bin/sh
# Regenerates ../ddl/10_seed.sql from MxAcctMGR's model files (no Xcode project build needed).
set -e
here=$(cd "$(dirname "$0")" && pwd)
app="$here/../../MxAcctMGR"
out=$(mktemp -d)
cd "$app"
swiftc -O -o "$out/seeddump" Universe.swift Portfolio.swift Samples.swift SRMData.swift Attribution.swift \
    MarketReports.swift ReportLibrary.swift BehaviorLab.swift Optimizer.swift ServiceClient.swift "$here/main.swift"
"$out/seeddump" "$here/../ddl/10_seed.sql"
rm -rf "$out"
