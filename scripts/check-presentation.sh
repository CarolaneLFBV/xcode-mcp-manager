#!/bin/bash
# Synthetic checks only: never launch an MCP server or write a real Xcode configuration.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/mcp-presentation-check.XXXXXX")"
cd "$project_root"
xcrun xcstringstool compile MCPManager/Resources/Localizable.xcstrings --output-directory "$check_directory"
xcrun swiftc -parse-as-library -module-cache-path "$check_directory/modules" \
  Shared/*.swift MCPManager/Models/*.swift MCPManager/Services/*.swift \
  MCPManager/ViewModels/*.swift MCPManagerTests/PresentationScenarios.swift \
  scripts/PresentationCheck.swift -o "$check_directory/presentation-check"
"$check_directory/presentation-check" "$check_directory"
echo "Temporary build artifacts: $check_directory"
