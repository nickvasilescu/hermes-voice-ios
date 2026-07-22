.PHONY: bootstrap check bridge-install bridge-dev bridge-build bridge-test bridge-typecheck ios-generate ios-test readme-images clean

# Installs deps and runs the full verification suite. Safe to run repeatedly.
bootstrap: bridge-install

# Bridge typecheck + tests. iOS is verified separately via `make ios-test`
# (requires Xcode + a simulator runtime on this Mac).
check: bootstrap
	@bash bootstrap/check.sh

bridge-install:
	cd bridge && npm ci

bridge-dev:
	cd bridge && npm run dev

bridge-build:
	cd bridge && npm run build

bridge-test:
	cd bridge && npm test

bridge-typecheck:
	cd bridge && npm run typecheck

# Regenerates ios/HermesVoice/HermesVoice.xcodeproj from project.yml.
# Requires XcodeGen (https://github.com/yonaskolb/XcodeGen) and Xcode.
ios-generate:
	cd ios/HermesVoice && xcodegen generate

# Build + run HermesVoiceTests on the iOS Simulator. Requires Xcode and an
# installed iOS Simulator runtime (`xcodebuild -downloadPlatform iOS`).
ios-test: ios-generate
	@SIMULATOR_ID="$$(bash scripts/select-ios-simulator.sh)"; \
	cd ios/HermesVoice && xcodebuild test -scheme HermesVoice \
		-destination "platform=iOS Simulator,id=$$SIMULATOR_ID" \
		-only-testing:HermesVoiceTests

readme-images:
	bash scripts/capture-readme-screenshots.sh

clean:
	rm -rf bridge/node_modules bridge/dist
	rm -rf ios/HermesVoice/HermesVoice.xcodeproj
	rm -rf ios/**/DerivedData
