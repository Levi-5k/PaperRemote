#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
destination="device-kit/Sources/PaperDeviceKit/Boards"
mkdir -p "$destination"
cp boards/*.json "$destination/"
