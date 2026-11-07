#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
swift build -c release --triple arm64-apple-macosx14.2
mkdir -p dist/RoomAudio.app/Contents/MacOS
cp .build/arm64-apple-macosx/release/RoomAudio dist/RoomAudio.app/Contents/MacOS/RoomAudio
cp Info.plist dist/RoomAudio.app/Contents/Info.plist
codesign --force --sign - --identifier local.roomaudio.app dist/RoomAudio.app
dist/RoomAudio.app/Contents/MacOS/RoomAudio --self-test
codesign --verify --deep --strict dist/RoomAudio.app
ditto -c -k --keepParent dist/RoomAudio.app dist/RoomAudio.zip
print "Built dist/RoomAudio.app and dist/RoomAudio.zip"
