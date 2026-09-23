#!/bin/bash
#
# Captures the running app on a simulator and copies the PNGs into
# ./Screenshots. These are the shots that have to come from a live app rather
# than from SnapshotComparisonTests:
#
#   app-reader-physical-damaged.png   page 3, composited and heavily worn
#   app-reader-pristine.png           the same page, every word restored
#   app-duo-cover.png                 the iPhone Duo's cover display, with the
#                                     debug HUD showing the measurements the
#                                     layout is actually working from
#
# The reader is opened by launch argument, not by tapping, so the same page and
# the same environment come back every run:
#
#   -paperbound-demo                  install the sample book and open it
#   -paperbound-demo-condition <c>    pristine | lightWear | wellLoved | damaged
#   -paperbound-demo-page N           1-based page to open at
#   -paperbound-demo-hud              overlay the live layout measurements
#
# Debug build only — every one of those arguments is compiled out of Release.
#
set -uo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DERIVED="${PROJECT_DIR}/.build/DerivedData"
OUT="${PROJECT_DIR}/Screenshots"
APPID="com.paperbound.reader"

PHONE="${1:-iPhone 17}"
DUO="${2:-iPhone Duo}"

# Long enough for the sample book to install, the reader to push, and the first
# page to composite. The compositor runs off the main thread, so a screenshot
# taken too early catches an empty sheet.
SETTLE=12

LOG="$(mktemp -t paperbound-captures)"

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

mkdir -p "${OUT}"

udid_for() {
    xcrun simctl list devices available \
        | grep -m1 "^    ${1} (" \
        | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/'
}

# Builds for one simulator and installs the result on it.
install_on() {
    local udid="$1" name="$2"
    echo "==> Building for '${name}'"
    xcodebuild \
        -project "${PROJECT_DIR}/Paperbound.xcodeproj" \
        -scheme Paperbound \
        -configuration Debug \
        -sdk iphonesimulator \
        -destination "platform=iOS Simulator,id=${udid}" \
        -derivedDataPath "${DERIVED}" \
        build > "${LOG}" 2>&1
    local status=$?
    if [ "${status}" -ne 0 ]; then
        echo "!! Build failed (exit ${status}). Full log: ${LOG}" >&2
        grep -E "error:" "${LOG}" | head >&2
        exit "${status}"
    fi

    local app
    app="$(find "${DERIVED}/Build/Products" -maxdepth 3 -name "Paperbound.app" \
           | grep -i simulator | head -1)"
    if [ -z "${app}" ]; then
        echo "!! Built no Paperbound.app under ${DERIVED}/Build/Products" >&2
        exit 1
    fi
    xcrun simctl install "${udid}" "${app}"
}

# capture <udid> <output name> <launch arguments...>
capture() {
    local udid="$1" name="$2"
    shift 2
    xcrun simctl terminate "${udid}" "${APPID}" > /dev/null 2>&1
    echo "==> Capturing ${name}"
    xcrun simctl launch "${udid}" "${APPID}" "$@" > /dev/null
    sleep "${SETTLE}"
    xcrun simctl io "${udid}" screenshot "${OUT}/${name}" > /dev/null 2>&1
    if [ ! -s "${OUT}/${name}" ]; then
        echo "!! ${name} came back empty" >&2
        exit 1
    fi
    echo "    $(sips -g pixelWidth -g pixelHeight "${OUT}/${name}" \
             | tail -2 | tr -d ' \n' | sed 's/pixelWidth:/ /;s/pixelHeight:/ × /')"
}

# --- The phone: worn and pristine, same page ---------------------------------

PHONE_UDID="$(udid_for "${PHONE}")"
if [ -z "${PHONE_UDID}" ]; then
    echo "!! No available simulator named '${PHONE}'" >&2
    exit 1
fi
xcrun simctl boot "${PHONE_UDID}" > /dev/null 2>&1
xcrun simctl bootstatus "${PHONE_UDID}" -b > /dev/null
install_on "${PHONE_UDID}" "${PHONE}"

capture "${PHONE_UDID}" "app-reader-physical-damaged.png" \
    -paperbound-demo -paperbound-demo-condition damaged -paperbound-demo-page 3
capture "${PHONE_UDID}" "app-reader-pristine.png" \
    -paperbound-demo -paperbound-demo-condition pristine -paperbound-demo-page 3

# --- The Duo: cover display, HUD showing -------------------------------------

DUO_UDID="$(udid_for "${DUO}")"
if [ -z "${DUO_UDID}" ]; then
    echo "==> No '${DUO}' simulator installed; skipping app-duo-cover.png"
else
    xcrun simctl boot "${DUO_UDID}" > /dev/null 2>&1
    xcrun simctl bootstatus "${DUO_UDID}" -b > /dev/null
    install_on "${DUO_UDID}" "${DUO}"

    capture "${DUO_UDID}" "app-duo-cover.png" \
        -paperbound-demo -paperbound-demo-condition wellLoved \
        -paperbound-demo-page 3 -paperbound-demo-hud
fi

echo "==> Wrote the app captures to ${OUT}"
ls -1 "${OUT}"/app-*.png
