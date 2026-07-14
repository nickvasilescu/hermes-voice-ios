.PHONY: bootstrap check bridge-install bridge-dev bridge-build bridge-test bridge-typecheck ios-generate ios-test dewey-smoke clean

# Installs deps and runs the full verification suite. Safe to run repeatedly.
bootstrap: bridge-install

# Bridge typecheck + tests. iOS is verified separately via `make ios-test`
# (requires Xcode + a simulator runtime on this Mac).
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
# Requires XcodeGen (https://github.com/yonaskolb/XcodeGen) and Xcode.
ios-generate:
	cd ios/HermesVoice && xcodegen generate

# Build + run HermesVoiceTests on the iOS Simulator. Requires Xcode and an
# installed iOS Simulator runtime (`xcodebuild -downloadPlatform iOS`).
ios-test: ios-generate
	cd ios/HermesVoice && xcodebuild test -scheme HermesVoice \
		-destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' \
		-only-testing:HermesVoiceTests

clean:
	rm -rf bridge/node_modules bridge/dist
	rm -rf ios/HermesVoice/HermesVoice.xcodeproj
	rm -rf ios/**/DerivedData