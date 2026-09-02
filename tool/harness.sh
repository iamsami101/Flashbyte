#!/usr/bin/env bash
# Flashbyte Test Harness & Continuous Verification Script

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"

cd "$PROJECT_DIR"

dart run tool/harness.dart "$@"
