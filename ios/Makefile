# Local iOS workflow. Requires Xcode and XcodeGen (`brew install xcodegen`).
SCHEME ?= Syrus
SIMULATOR ?= platform=iOS Simulator,name=iPhone 17
DERIVED ?= build/DerivedData
XCB = xcodebuild -project Syrus.xcodeproj -scheme $(SCHEME) -destination '$(SIMULATOR)' -derivedDataPath $(DERIVED) CODE_SIGNING_ALLOWED=NO

.PHONY: generate build test open clean archive export upload
generate:
	xcodegen generate

build: generate
	$(XCB) build

test: generate
	$(XCB) test

open: generate
	open Syrus.xcodeproj

clean:
	rm -rf build Syrus.xcodeproj

# Signed release path; credentials come from the environment (see README).
archive export upload:
	scripts/release.sh $@
