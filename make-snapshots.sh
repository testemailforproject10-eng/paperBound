#!/bin/bash
#
# Renders both snapshot sets and copies them out of the simulator into
# ./Screenshots:
#
#   text-*/figure-*/material-*   the condition comparison. Every image is the
#                                same page of the same book at the same size —
#                                only the page condition changes.
#   duo-*                        what the iPhone Duo shows on each of its two
#                                displays, through the same layout coordinator
#                                and compositor the live app uses.
#
# Both sets come from SnapshotComparisonTests, so a layout or compositor
# regression fails the run rather than quietly producing a wrong picture.
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICE="${1:-iPhone 17}"
DERIVED="${PROJECT_DIR}/.build/DerivedData"
OUT="${PROJECT_DIR}/Screenshots"

LOG="$(mktemp -t paperbound-snapshots)"

# The project compiles against UIHingeInteraction, which exists only in the
# iOS 27.1 SDK. Under an older Xcode this fails a long way into a build log, so
# check here and say what to do about it.
require_sdk_27_1() {
    local sdk
    sdk="$(xcodebuild -showsdks 2>/dev/null \
           | sed -n 's/.*-sdk iphonesimulator\([0-9][0-9.]*\).*/\1/p' \
           | sort -V | tail -1)"
    if [ -z "${sdk}" ]; then
        echo "!! No iphonesimulator SDK found. Is Xcode installed and selected?" >&2
        exit 1
    fi
    if [ "$(printf '%s\n27.1\n' "${sdk}" | sort -V | head -1)" != "27.1" ]; then
        echo "!! The active toolchain has the iOS ${sdk} SDK; this project needs 27.1." >&2
        echo "   UIHingeInteraction does not exist before 27.1." >&2
        echo "   Fix:  sudo xcode-select -s /path/to/Xcode-27.1.app/Contents/Developer" >&2
        echo "   Or:   DEVELOPER_DIR=/path/to/Xcode-27.1.app/Contents/Developer $0" >&2
        exit 1
    fi
}
require_sdk_27_1

echo "==> Rendering comparison and iPhone Duo snapshots on '${DEVICE}'"
# Note: no `|| true` here. A build failure must stop the script, or it happily
# copies out whatever stale images the previous run left in the container.
set +e
xcodebuild \
    -project "${PROJECT_DIR}/Paperbound.xcodeproj" \
    -scheme Paperbound \
    -sdk iphonesimulator \
    -destination "platform=iOS Simulator,name=${DEVICE}" \
    -derivedDataPath "${DERIVED}" \
    -only-testing:PaperboundTests/SnapshotComparisonTests \
    test > "${LOG}" 2>&1
STATUS=$?
set -e

grep -E "Test Case.*(passed|failed)|Executed [0-9]+ test|snapshots written|error:" "${LOG}" || true

if [ "${STATUS}" -ne 0 ]; then
    echo "!! Rendering failed (exit ${STATUS}). Full log: ${LOG}" >&2
    exit "${STATUS}"
fi

# The test prints the absolute host path it wrote to. Trust that rather than
# re-deriving the container: Xcode sometimes removes the app after a test
# session, and then `simctl get_app_container` has nothing to report.
SRC="$(sed -n 's/^Paperbound snapshots written to: //p' "${LOG}" | tail -1)"

if [ -z "${SRC}" ] || [ ! -d "${SRC}" ]; then
    UDID="$(xcrun simctl list devices | grep -m1 "${DEVICE} (" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
    CONTAINER="$(xcrun simctl get_app_container "${UDID:-booted}" com.paperbound.reader data 2>/dev/null || true)"
    SRC="${CONTAINER}/tmp/PaperboundSnapshots"
fi

if [ ! -d "${SRC}" ]; then
    echo "!! Could not locate the rendered snapshots. Full log: ${LOG}" >&2
    exit 1
fi

# Remove only what this script regenerates. The app-*.png captures in the same
# folder come from a running simulator rather than from the test, and the
# blanket `rm -rf "${OUT}"` this used to do deleted them on every run.
mkdir -p "${OUT}"
rm -f "${OUT}"/text-*.png "${OUT}"/figure-*.png "${OUT}"/material-*.png \
      "${OUT}"/duo-*.png "${OUT}"/index.txt
cp "${SRC}"/*.png "${OUT}/"

echo "==> Wrote $(ls -1 "${OUT}"/*.png | wc -l | tr -d ' ') images to ${OUT}"
ls -1 "${OUT}"
