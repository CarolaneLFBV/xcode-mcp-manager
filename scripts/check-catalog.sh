#!/bin/bash
# Compile synthetic catalog checks outside the source tree; no provider is contacted.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/mcp-catalog-check.XXXXXX")"
cd "$project_root"
xcrun swiftc -parse-as-library -module-cache-path "$check_directory/modules" \
  Shared/*.swift MCPManager/Models/*.swift MCPManager/Services/*.swift MCPManager/ViewModels/*.swift \
  MCPManagerTests/*Scenarios.swift scripts/CatalogCheck.swift \
  -o "$check_directory/catalog-check"
"$check_directory/catalog-check"
echo "Temporary build artifacts: $check_directory"
