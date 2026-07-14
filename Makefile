.PHONY: bootstrap check bridge-install bridge-dev bridge-build bridge-test bridge-typecheck ios-generate dewey-smoke clean

# Installs deps and runs the full verification suite. Safe to run repeatedly.
bootstrap: bridge-install

# Runs everything CI runs: typecheck + tests. Does NOT attempt to build the
# iOS app (no Xcode/iOS SDK on Linux CI; see docs/ARCHITECTURE.md).
check: bootstrap bridge-typecheck bridge-test
	@bash bootstrap/check.sh

bridge-install:
	cd bridge && npm install

bridge-dev:
	cd bridge && npm run dev

bridge-build:
	cd bridge && npm run build

bridge-test:
	cd bridge && npm test

bridge-typecheck:
	cd bridge && npm run typecheck

# Hits the public Dewey tunnel (health → session → Hermes task → realtime mint).
# Requires the bridge to be running on Dewey; see scripts/dewey/.
dewey-smoke:
	bash scripts/dewey/smoke-bridge.sh

# Regenerates ios/HermesVoice/HermesVoice.xcodeproj from project.yml.
# Requires XcodeGen (https://github.com/yonaskolb/XcodeGen) and Xcode, so
# this only works on macOS.
ios-generate:
	cd ios/HermesVoice && xcodegen generate

clean:
	rm -rf bridge/node_modules bridge/dist
	rm -rf ios/HermesVoice/HermesVoice.xcodeproj
