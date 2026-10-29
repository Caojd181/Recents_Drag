#!/bin/zsh
set -eu
cd "${0:A:h}"
task_app="$PWD/.build/RecentsDragDemo.app"
task_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$task_app/Contents/Info.plist")
task_arch=$(/usr/bin/lipo -archs "$task_app/Contents/MacOS/RecentsDragDemo")
task_stage="$PWD/.build/package-root"
task_image="$PWD/dist/Recents-Drag-${task_version}-${task_arch}.dmg"
/usr/bin/codesign --verify --strict "$task_app"
/bin/mkdir -p "$PWD/dist"
/bin/rm -rf "$task_stage"
/bin/mkdir -p "$task_stage"
/usr/bin/ditto "$task_app" "$task_stage/Recents Drag.app"
/bin/ln -s /Applications "$task_stage/Applications"
/usr/bin/hdiutil create -volname 'Recents Drag' -srcfolder "$task_stage" -fs HFS+ -format UDZO -ov "$task_image"
/bin/rm -rf "$task_stage"
print "Packaged: $task_image"
