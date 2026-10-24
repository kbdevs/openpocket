#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
export DEVELOPER_DIR

python3 "$SCRIPT_DIR/prepare-voice-model.py"

if ! command -v xcodegen >/dev/null 2>&1; then
	printf '%s\n' 'XcodeGen 2.46.0 or later is required to generate PocketBridge.xcodeproj.' >&2
	exit 127
fi
xcodegen generate --spec "$ROOT_DIR/project.yml" --project-root "$ROOT_DIR/ios" --project "$ROOT_DIR/ios"

MODE=${1:-build}
# Tests run on SIMULATOR_NAME, or SIMULATOR_ID when set.
SIMULATOR_NAME=${SIMULATOR_NAME:-iPhone 17}
set -- -project "$ROOT_DIR/ios/PocketBridge.xcodeproj" \
	-scheme PocketBridge -configuration Debug -sdk iphonesimulator \
	CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-

case "$MODE" in
	build)
		set -- "$@" -destination 'generic/platform=iOS Simulator' build
		;;
	test)
		if [ -n "${SIMULATOR_ID:-}" ]; then DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"; else DESTINATION="platform=iOS Simulator,name=$SIMULATOR_NAME"; fi
		set -- "$@" -destination "$DESTINATION" test
		;;
	*)
		printf 'Usage: %s [build|test]\n' "$0" >&2
		exit 2
		;;
esac

exec xcodebuild "$@"
