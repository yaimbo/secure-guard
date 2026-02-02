#!/bin/bash
#
# release-build.sh - Release build orchestration for MinnowVPN
#
# Builds all release artifacts:
#   - macOS: Universal PKG installer
#   - Linux: deb and rpm packages for amd64 and arm64
#   - Docker: Multi-arch images pushed to Docker Hub
#   - Windows: Version updated only (build separately on Windows)
#
# Usage:
#   ./scripts/release-build.sh 1.2.0              # Explicit version
#   ./scripts/release-build.sh patch              # Bump patch and build
#   ./scripts/release-build.sh 1.2.0 --skip-docker
#   ./scripts/release-build.sh 1.2.0 --skip-linux
#   ./scripts/release-build.sh 1.2.0 --macos-only
#   ./scripts/release-build.sh 1.2.0 --dry-run
#

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"
ARTIFACTS_DIR="$PROJECT_ROOT/release-artifacts"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${CYAN}=== $1 ===${NC}\n"; }

usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] <bump-type|version>

Arguments:
  bump-type    One of: major, minor, patch
  version      Explicit semver (e.g., 1.2.3 or 1.2.3-beta.1)

Options:
  --skip-docker     Skip Docker image build
  --skip-linux      Skip Linux package builds
  --skip-macos      Skip macOS build
  --macos-only      Only build macOS
  --linux-only      Only build Linux packages
  --docker-only     Only build Docker images
  --dry-run         Show what would be built without building
  --no-push         Build Docker images but don't push
  --help            Show this help message

Linux builds include:
  - amd64/x86_64: .deb (Ubuntu/Debian) and .rpm (RHEL/Fedora)
  - arm64/aarch64: .deb (Ubuntu/Debian) and .rpm (RHEL/Fedora)

Examples:
  $(basename "$0") 1.2.0                    # Build all with explicit version
  $(basename "$0") patch                    # Bump patch and build all
  $(basename "$0") 1.2.0 --skip-docker      # Build clients only
  $(basename "$0") 1.2.0 --linux-only       # Linux packages only
  $(basename "$0") 1.2.0 --dry-run          # Preview build plan
EOF
    exit 0
}

# Build status tracking (bash 3.2 compatible)
STATUS_MACOS=""
STATUS_LINUX_AMD64=""
STATUS_LINUX_ARM64=""
STATUS_DOCKER=""
FAILED_BUILDS=""

# Options
SKIP_DOCKER=false
SKIP_LINUX=false
SKIP_MACOS=false
DRY_RUN=false
NO_PUSH=false
VERSION_OR_BUMP=""

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-docker)
                SKIP_DOCKER=true
                shift
                ;;
            --skip-linux)
                SKIP_LINUX=true
                shift
                ;;
            --skip-macos)
                SKIP_MACOS=true
                shift
                ;;
            --macos-only)
                SKIP_DOCKER=true
                SKIP_LINUX=true
                shift
                ;;
            --linux-only)
                SKIP_DOCKER=true
                SKIP_MACOS=true
                shift
                ;;
            --docker-only)
                SKIP_LINUX=true
                SKIP_MACOS=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --no-push)
                NO_PUSH=true
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                if [[ -z "$VERSION_OR_BUMP" ]]; then
                    VERSION_OR_BUMP="$1"
                else
                    log_error "Unknown argument: $1"
                    usage
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$VERSION_OR_BUMP" ]]; then
        log_error "Missing version or bump type"
        usage
    fi
}

# Bump version using version-bump.sh
bump_version() {
    log_step "Bumping version ($VERSION_OR_BUMP)"

    if $DRY_RUN; then
        "$SCRIPTS_DIR/version-bump.sh" --dry-run "$VERSION_OR_BUMP"
    else
        "$SCRIPTS_DIR/version-bump.sh" "$VERSION_OR_BUMP"
    fi

    # Get the actual version (in case bump type was used)
    VERSION=$("$SCRIPTS_DIR/version-bump.sh" --current)
    log_info "Building version: $VERSION"
}

# Build macOS
build_macos() {
    log_step "Building macOS Package"

    if $DRY_RUN; then
        echo "Would run: installer/macos/build-dmg.sh $VERSION"
        STATUS_MACOS="dry-run"
        return
    fi

    local start_time=$(date +%s)

    if "$PROJECT_ROOT/installer/macos/build-dmg.sh" "$VERSION"; then
        STATUS_MACOS="success"
        local elapsed=$(($(date +%s) - start_time))
        log_success "macOS build completed in ${elapsed}s"

        # Copy artifact
        if [[ -f "$PROJECT_ROOT/installer/macos/build/MinnowVPN-$VERSION.pkg" ]]; then
            cp "$PROJECT_ROOT/installer/macos/build/MinnowVPN-$VERSION.pkg" "$ARTIFACTS_DIR/$VERSION/"
            log_info "Artifact: MinnowVPN-$VERSION.pkg"
        fi
    else
        STATUS_MACOS="failed"
        FAILED_BUILDS="$FAILED_BUILDS macos"
        log_error "macOS build failed"
    fi
}

# Build Linux packages (all architectures and formats)
build_linux() {
    log_step "Building Linux Packages (amd64 + arm64, deb + rpm)"

    if $DRY_RUN; then
        echo "Would run: installer/linux/build-package.sh $VERSION --arch=x86_64 --format=all"
        echo "Would run: installer/linux/build-package.sh $VERSION --arch=aarch64 --format=all"
        STATUS_LINUX_AMD64="dry-run"
        STATUS_LINUX_ARM64="dry-run"
        return
    fi

    # Build amd64 packages
    log_info "Building amd64 packages..."
    local start_time=$(date +%s)

    if "$PROJECT_ROOT/installer/linux/build-package.sh" "$VERSION" --arch=x86_64 --format=all; then
        STATUS_LINUX_AMD64="success"
        local elapsed=$(($(date +%s) - start_time))
        log_success "amd64 packages completed in ${elapsed}s"
    else
        STATUS_LINUX_AMD64="failed"
        FAILED_BUILDS="$FAILED_BUILDS linux_amd64"
        log_error "amd64 package build failed"
    fi

    # Build arm64 packages
    log_info "Building arm64 packages..."
    start_time=$(date +%s)

    if "$PROJECT_ROOT/installer/linux/build-package.sh" "$VERSION" --arch=aarch64 --format=all; then
        STATUS_LINUX_ARM64="success"
        local elapsed=$(($(date +%s) - start_time))
        log_success "arm64 packages completed in ${elapsed}s"
    else
        STATUS_LINUX_ARM64="failed"
        FAILED_BUILDS="$FAILED_BUILDS linux_arm64"
        log_error "arm64 package build failed"
    fi

    # Copy artifacts
    for pkg in "$PROJECT_ROOT/installer/linux/build/"*.deb "$PROJECT_ROOT/installer/linux/build/"*.rpm; do
        if [[ -f "$pkg" ]]; then
            cp "$pkg" "$ARTIFACTS_DIR/$VERSION/"
            log_info "Artifact: $(basename "$pkg")"
        fi
    done
}

# Build Docker images
build_docker() {
    log_step "Building Docker Images (amd64 + arm64)"

    local push_flag=""
    if $NO_PUSH; then
        push_flag="--no-push"
    fi

    if $DRY_RUN; then
        echo "Would run: installer/docker/scripts/publish.sh $VERSION -y $push_flag"
        STATUS_DOCKER="dry-run"
        return
    fi

    local start_time=$(date +%s)

    if "$PROJECT_ROOT/installer/docker/scripts/publish.sh" "$VERSION" -y $push_flag; then
        STATUS_DOCKER="success"
        local elapsed=$(($(date +%s) - start_time))
        log_success "Docker build completed in ${elapsed}s"
    else
        STATUS_DOCKER="failed"
        FAILED_BUILDS="$FAILED_BUILDS docker"
        log_error "Docker build failed"
    fi
}

# Print status with color
print_status() {
    local status="$1"
    case "$status" in
        success)  echo -e "${GREEN}SUCCESS${NC}" ;;
        failed)   echo -e "${RED}FAILED${NC}" ;;
        dry-run)  echo -e "${YELLOW}DRY-RUN${NC}" ;;
        *)        echo "UNKNOWN" ;;
    esac
}

# Print build summary
print_summary() {
    log_step "Release Build Summary"

    echo "Version: $VERSION"
    echo ""
    echo "Build Results:"
    echo "--------------"

    # macOS
    if $SKIP_MACOS; then
        echo "  macOS:           SKIPPED"
    elif [[ -n "$STATUS_MACOS" ]]; then
        echo -e "  macOS:           $(print_status "$STATUS_MACOS")"
    fi

    # Linux
    if $SKIP_LINUX; then
        echo "  Linux:           SKIPPED"
    else
        if [[ -n "$STATUS_LINUX_AMD64" ]]; then
            echo -e "  Linux amd64:     $(print_status "$STATUS_LINUX_AMD64")"
        fi
        if [[ -n "$STATUS_LINUX_ARM64" ]]; then
            echo -e "  Linux arm64:     $(print_status "$STATUS_LINUX_ARM64")"
        fi
    fi

    # Docker
    if $SKIP_DOCKER; then
        echo "  Docker:          SKIPPED"
    elif [[ -n "$STATUS_DOCKER" ]]; then
        echo -e "  Docker:          $(print_status "$STATUS_DOCKER")"
    fi

    # Windows note
    echo ""
    echo "  Windows:         VERSION UPDATED (build separately on Windows)"

    # Artifacts
    if [[ -d "$ARTIFACTS_DIR/$VERSION" ]] && ! $DRY_RUN; then
        echo ""
        echo "Artifacts:"
        echo "----------"
        ls -la "$ARTIFACTS_DIR/$VERSION/" 2>/dev/null | tail -n +2 || echo "  (none)"
    fi

    # Docker images
    if ! $SKIP_DOCKER && [[ "$STATUS_DOCKER" == "success" ]]; then
        echo ""
        echo "Docker Images:"
        echo "--------------"
        echo "  minnowvpn/api:$VERSION"
        echo "  minnowvpn/console:$VERSION"
        echo "  minnowvpn/vpn:$VERSION"
        if ! $NO_PUSH; then
            echo "  (pushed to Docker Hub)"
        else
            echo "  (local only, not pushed)"
        fi
    fi

    # Failed builds
    if [[ -n "$FAILED_BUILDS" ]]; then
        echo ""
        log_error "Some builds failed:$FAILED_BUILDS"
        exit 1
    fi

    if $DRY_RUN; then
        echo ""
        log_warn "DRY RUN complete - no builds were executed"
    else
        echo ""
        log_success "Release build complete!"
        echo ""
        echo "Next steps:"
        echo "  1. Review changes: git diff"
        echo "  2. Commit: git add -A && git commit -m \"Release $VERSION\""
        echo "  3. Tag: git tag -a \"v$VERSION\" -m \"Release $VERSION\""
        echo "  4. Push: git push origin main --tags"
        echo "  5. Build Windows: Run 'makensis installer/windows/secureguard.nsi' on Windows"
    fi
}

# Main
main() {
    parse_args "$@"

    echo ""
    echo "============================================================"
    echo "              MinnowVPN Release Build"
    echo "============================================================"
    echo ""

    # Check for required tools
    if ! command -v git &> /dev/null; then
        log_error "git is required but not installed"
        exit 1
    fi

    # Check working directory is clean (warn if not)
    if [[ -n "$(git -C "$PROJECT_ROOT" status --porcelain)" ]]; then
        log_warn "Working directory has uncommitted changes"
        if ! $DRY_RUN; then
            read -p "Continue anyway? [y/N] " -n 1 -r
            echo
            if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                exit 1
            fi
        fi
    fi

    # Bump version
    bump_version

    # Create artifacts directory
    if ! $DRY_RUN; then
        mkdir -p "$ARTIFACTS_DIR/$VERSION"
    fi

    # Build each platform
    if ! $SKIP_MACOS; then
        build_macos
    fi

    if ! $SKIP_LINUX; then
        build_linux
    fi

    if ! $SKIP_DOCKER; then
        build_docker
    fi

    # Print summary
    print_summary
}

main "$@"
