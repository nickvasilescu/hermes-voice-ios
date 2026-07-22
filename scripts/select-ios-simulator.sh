#!/usr/bin/env bash
set -euo pipefail

command -v xcrun >/dev/null 2>&1 || {
  echo "xcrun is required to select an iOS Simulator" >&2
  exit 1
}

xcrun simctl list devices available -j | node --input-type=module -e '
  let input = "";
  for await (const chunk of process.stdin) input += chunk;
  const runtimes = JSON.parse(input).devices;
  const candidates = Object.entries(runtimes)
    .filter(([runtime]) => runtime.includes("iOS"))
    .flatMap(([runtime, devices]) => devices
      .filter((device) => device.isAvailable && device.name.startsWith("iPhone"))
      .map((device) => ({ runtime, ...device })));
  candidates.sort((a, b) => b.runtime.localeCompare(a.runtime, undefined, { numeric: true }));
  if (!candidates[0]) {
    console.error("No available iPhone Simulator was found. Install an iOS runtime in Xcode.");
    process.exit(1);
  }
  process.stdout.write(candidates[0].udid);
'
