# Convenience entry points. The `version` target (re)generates the embedded
# version string before any build, so `boattools --version` is always accurate.
# Plain `swift build` works too, but only `make` keeps the version up to date.

TOOL         := boattools
VERSION_FILE := Sources/BoatTools/Version.generated.swift

.PHONY: all build release run test version clean

all: build

# Regenerate the embedded version string (tag on a release, dev-<date> otherwise).
version:
	@./Scripts/version.sh "$(VERSION_FILE)"

build: version
	swift build

release: version
	swift build -c release

run: version
	swift run $(TOOL)

test: version
	swift test

clean:
	swift package clean
	rm -f "$(VERSION_FILE)"
