#!/bin/bash
# =============================================================================
# SecureGuard VPN - Quick Install
# =============================================================================
#
# This is the entry point for installing SecureGuard VPN Server.
# It simply calls the setup script with any provided arguments.
#
# Usage:
#   ./install.sh                    # Interactive setup
#   ./install.sh --non-interactive  # Use environment variables (for CI/CD)
#
# For more information, see README.md
#
# =============================================================================

cd "$(dirname "$0")"
exec ./scripts/setup.sh "$@"
