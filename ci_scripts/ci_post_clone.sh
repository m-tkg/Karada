#!/bin/sh

# Xcode Cloud hook: generate Karada.xcodeproj after checkout.
# The project file is generated from project.yml and is not committed.

set -e

echo "==> Installing xcodegen"
brew install xcodegen

echo "==> Generating Karada.xcodeproj"
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate
