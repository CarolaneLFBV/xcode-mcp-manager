#!/bin/bash
# Synthetic sessions only: no real server, provider account or Keychain access.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/mcp-supervisor-check.XXXXXX")"
cd "$project_root"
xcrun swiftc -parse-as-library -module-cache-path "$check_directory/modules" \
  Shared/*.swift MCPManager/Models/*.swift MCPManager/Services/*.swift \
  MCPManagerTests/SupervisorScenarios.swift scripts/SupervisorCheck.swift \
  -o "$check_directory/supervisor-check"
"$check_directory/supervisor-check" "$check_directory"
echo "Temporary build artifacts: $check_directory"
