#!/usr/bin/env bash
# ios-builder setup for the WYM C2 server (Linux/macOS).
#
# Installs the MobAI ios-builder CLI (https://github.com/MobAI-App/ios-builder),
# authenticates it with GitHub and initializes the Actions workflow this repo
# needs so `POST /api/build/start` can produce iOS (.ipa) agents on a non-macOS
# server: ios-builder snapshots the working tree, builds on a GitHub macOS
# runner (free on public repos) and downloads the IPA to ./dist/.
set -euo pipefail

if ! command -v builder >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        brew install mobai-app/tap/ios-builder
    elif command -v curl >/dev/null 2>&1; then
        curl -sSL https://raw.githubusercontent.com/MobAI-App/ios-builder/main/install.sh | bash
    else
        echo "install builder manually from https://github.com/MobAI-App/ios-builder/releases" >&2
        exit 1
    fi
fi

# Token is stored in your OS keychain, never in the repo. Needs a GitHub token
# with `repo` + `workflow` scopes.
builder auth github

echo "Initializing the ios-builder workflow (.github/workflows/ios-build.yml) ..."
builder init --ios-path clients/mobile/ios --scheme WymC2 --project WymC2

echo "Done. The server auto-detects 'builder' on PATH; try an iOS build from the Generate Agent page."