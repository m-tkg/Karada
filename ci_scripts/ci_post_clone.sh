#!/bin/sh

# Xcode Cloud hook: keep Karada.xcodeproj in sync with project.yml.
# Karada.xcodeproj is committed so Xcode Cloud can discover the project.

set -e

echo "==> Installing xcodegen"
brew install xcodegen

echo "==> Generating Karada.xcodeproj"
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate
