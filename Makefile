.PHONY: help ios-generate ios-build ios-deploy release-tag

PROJECT      = Karada.xcodeproj
SCHEME       = Karada
BUNDLE_ID    = com.mtkg.karada
DERIVED_DATA = .build/ios

# Override with: make ios-deploy DEVICE_ID=<device-udid>
DEVICE_ID ?= 620080DD-019A-5477-8F2D-96E9E0C8C538
VERSION := $(shell sed -n 's/^[[:space:]]*MARKETING_VERSION:[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}/\1/p' project.yml | head -1)
TAG     := v$(VERSION)

help:
	@echo "make ios-build              -> Build for a generic iOS device"
	@echo "make ios-deploy             -> Build Release, install on DEVICE_ID, and launch"
	@echo "make ios-deploy DEVICE_ID=... -> Use a different connected device"
	@echo "make release-tag            -> Push $(TAG) to trigger Xcode Cloud"

ios-generate:
	xcodegen generate

ios-build: ios-generate
	xcodebuild build \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-destination "generic/platform=iOS" \
		-derivedDataPath $(DERIVED_DATA) \
		-allowProvisioningUpdates \
		-quiet

ios-deploy: ios-generate
	@echo "==> Building Release for device $(DEVICE_ID)..."
	xcodebuild build \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination "platform=iOS,id=$(DEVICE_ID)" \
		-derivedDataPath $(DERIVED_DATA) \
		-allowProvisioningUpdates \
		-quiet
	@echo "==> Installing on device..."
	xcrun devicectl device install app \
		--device $(DEVICE_ID) \
		"$(DERIVED_DATA)/Build/Products/Release-iphoneos/$(SCHEME).app"
	@echo "==> Launching app..."
	xcrun devicectl device process launch \
		--device $(DEVICE_ID) \
		$(BUNDLE_ID)

release-tag:
	@if [ -z "$(VERSION)" ]; then \
		echo "error: MARKETING_VERSION not found in project.yml" >&2; \
		exit 1; \
	fi
	@branch="$$(git rev-parse --abbrev-ref HEAD)"; \
	if [ "$$branch" != "main" ]; then \
		echo "error: must be on main to cut a release (current: $$branch)" >&2; \
		exit 1; \
	fi
	@if [ -n "$$(git status --porcelain)" ]; then \
		echo "error: working tree is not clean" >&2; \
		exit 1; \
	fi
	@git fetch origin main --quiet
	@if [ "$$(git rev-parse HEAD)" != "$$(git rev-parse origin/main)" ]; then \
		echo "error: local main is not up to date with origin/main" >&2; \
		exit 1; \
	fi
	@if git rev-parse "$(TAG)" >/dev/null 2>&1; then \
		echo "error: tag $(TAG) already exists" >&2; \
		exit 1; \
	fi
	git tag -a "$(TAG)" -m "Release $(TAG)"
	git push origin "$(TAG)"
	@echo "Pushed tag $(TAG); Xcode Cloud should start if its workflow is configured for tag pushes."
