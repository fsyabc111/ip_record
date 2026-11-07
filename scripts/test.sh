#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
# CLT 27's native SwiftPM backend needs the bundled Testing framework search path.
swift test --build-system native -Xswiftc "-F$frameworks" -Xlinker -rpath -Xlinker "$frameworks" "$@"
