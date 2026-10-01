#!/bin/zsh
# Runs the checks for the sync core, scheduling and Web Push crypto (no Xcode project needed).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc -O -module-name UpkeepCore -o build/tests/core \
  Upkeep/Core/SyncCore.swift Upkeep/Core/PhoneServer/WebPushCrypto.swift Upkeep/Modules/Maintenance/Schedule.swift Upkeep/Modules/Maintenance/Catalog.swift \
  Upkeep/Core/PhoneHostName.swift Upkeep/Core/PushSchedule.swift Upkeep/Core/HouseholdCheck.swift \
  Upkeep/Core/Names.swift Upkeep/Core/FileNames.swift Upkeep/Core/Devices.swift Upkeep/Core/PhoneServer/PushResult.swift \
  Tests/Core/main.swift 2>&1 | grep -v "^$" || true
build/tests/core Web/test/fixtures
