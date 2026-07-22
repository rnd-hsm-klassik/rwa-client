#!/bin/bash

VERSION="$1"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version>"
    exit 1
fi

PROJECT_FILE="rwaClient/rwaclient.xcodeproj/project.pbxproj"
sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = ${VERSION};/g" "$PROJECT_FILE"

# # CFBundleShortVersionString is currently interpolated from MARKETING_VERSION
# PLIST_FILE="rwaClient/src/Info.plist"
# plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST_FILE"
