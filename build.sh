#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p .build/module-cache .build/RecentsDragDemo.app/Contents/MacOS .build/RecentsDragDemo.app/Contents/Resources
task_target_arch=$(/usr/bin/uname -m)
/usr/bin/xcrun swiftc -swift-version 5 -O -target "${task_target_arch}-apple-macos14.0" \
  -module-cache-path "$PWD/.build/module-cache" \
  -framework AppKit -framework ApplicationServices -framework CoreServices \
  Sources/*.swift -o .build/RecentsDragDemo.app/Contents/MacOS/RecentsDragDemo
/bin/rm -rf .build/RecentsDragDemo.app/Contents/MacOS/RecentsDragDemo.dSYM
/bin/cp Resources/Info.plist .build/RecentsDragDemo.app/Contents/Info.plist
/bin/cp Resources/AppIcon.icns .build/RecentsDragDemo.app/Contents/Resources/AppIcon.icns
/usr/bin/codesign --force --sign - --identifier com.caojd.RecentsDragDemo .build/RecentsDragDemo.app
print "Built: $PWD/.build/RecentsDragDemo.app"
