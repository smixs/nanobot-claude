#!/usr/bin/env bash
# Build-based integration test: if the Docker image builds successfully,
# install.sh ran end-to-end and every assertion layer passed. No separate
# `docker run` step is needed — failure of any RUN command fails the build.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "▶ Building test image (runs install.sh with mocked claude/systemctl)..."
docker build -f tests/bootstrap.dockerfile -t nanobot-claude-oauth-test .

echo
echo "✓ Docker smoke test passed — install.sh completed and produced the expected"
echo "  ~/.nanobot/config.json and systemd unit files with the resolved claude path."
echo
echo "Not covered here (requires real environment):"
echo "  • bootstrap.sh TUI flow — manual test on a fresh VPS"
echo "  • claude OAuth login — browser-only, cannot be mocked meaningfully"
echo "  • live HTTP smoke test — requires real systemd to start the shim"
