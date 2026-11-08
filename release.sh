#!/bin/bash

# RoMa Matcher v2 Compose — release script.
# Pins the version (update-version.sh set), commits and pushes master, then creates and
# pushes the git tag that AutoUpdater detects.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
FORMAT="text"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_usage() {
    echo -e "${BLUE}RoMa Matcher v2 Compose Release Script${NC}"
    echo
    echo "Usage: ./release.sh [VERSION] [OPTIONS]"
    echo
    echo "Arguments:"
    echo "  VERSION     Semantic version X.Y.Z (e.g., 0.2.0)."
    echo "              If omitted, uses the version pinned in roma-matcher-v2.version."
    echo
    echo "Options:"
    echo "  -m, --message TEXT    Commit message (default: 'release: vX.Y.Z')"
    echo "  --dry-run             Show what would be done without executing"
    echo "  --format=json         Output the result as JSON (for scripting)"
    echo "  -h, --help            Show this help message"
    echo
    echo "JSON OUTPUT FORMAT:"
    echo "  {\"success\": true, \"version\": \"0.2.0\"}"
    echo "  {\"success\": false, \"error\": \"error message\"}"
}

print_error()   { echo -e "${RED}Error: $1${NC}" >&2; }
print_warning() { if [ "$FORMAT" = "json" ]; then echo -e "${YELLOW}Warning: $1${NC}" >&2; else echo -e "${YELLOW}Warning: $1${NC}"; fi }
print_success() { if [ "$FORMAT" = "json" ]; then echo -e "${GREEN}$1${NC}" >&2; else echo -e "${GREEN}$1${NC}"; fi }
print_info()    { if [ "$FORMAT" = "json" ]; then echo -e "${BLUE}$1${NC}" >&2; else echo -e "${BLUE}$1${NC}"; fi }

validate_version() {
    if [[ ! $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        print_error "Invalid version format: $1. Expected X.Y.Z (e.g., 0.2.0)"
        return 1
    fi
}

get_pinned_version() {
    if [[ -f "$SCRIPT_DIR/roma-matcher-v2.version" ]]; then
        tr -d '[:space:]' < "$SCRIPT_DIR/roma-matcher-v2.version"
    else
        print_error "roma-matcher-v2.version file not found"
        return 1
    fi
}

main() {
    local version="" message="" dry_run=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help) print_usage; exit 0 ;;
            --dry-run) dry_run=true; shift ;;
            --format=json) FORMAT="json"; shift ;;
            -m|--message) message="$2"; shift 2 ;;
            -*) print_error "Unknown option: $1"; print_usage; exit 1 ;;
            *)
                if [[ -z "$version" ]]; then version="$1"; shift
                else print_error "Too many arguments"; print_usage; exit 1
                fi
                ;;
        esac
    done

    if [[ -z "$version" ]]; then
        version=$(get_pinned_version) || exit 1
        print_info "Using pinned version: $version"
    fi
    validate_version "$version" || exit 1

    local tag="v$version"

    if [[ "$dry_run" == true ]]; then
        print_info "🔍 DRY RUN — would perform:"
        print_info "1. ./update-version.sh set $version"
        print_info "2. Commit with message: ${message:-"release: $tag"}"
        print_info "3. git push origin (master)"
        print_info "4. Create and push tag: $tag"
        exit 0
    fi

    print_info "🚀 Releasing RoMa Matcher v2 Compose $version"

    # Pin the image tag + version file (idempotent — no-op if already pinned).
    "$SCRIPT_DIR/update-version.sh" set "$version" || { print_error "update-version.sh set failed"; exit 1; }

    if git -C "$SCRIPT_DIR" tag -l | grep -qx "$tag"; then
        print_error "Tag $tag already exists"
        exit 1
    fi

    if [[ -n $(git -C "$SCRIPT_DIR" status --porcelain) ]]; then
        print_info "Committing changes..."
        git -C "$SCRIPT_DIR" add -A
        git -C "$SCRIPT_DIR" commit -m "${message:-release: $tag}"
        print_success "✓ Changes committed"
    else
        print_warning "No changes to commit (version already pinned)"
    fi

    print_info "Pushing commit to origin..."
    git -C "$SCRIPT_DIR" push origin HEAD:master
    print_success "✓ Commit pushed"

    print_info "Creating tag $tag..."
    git -C "$SCRIPT_DIR" tag "$tag"
    git -C "$SCRIPT_DIR" push origin "$tag"
    print_success "✅ Tag $tag created and pushed"

    if [[ "$FORMAT" = "json" ]]; then
        echo "{\"success\": true, \"version\": \"$version\"}"
    else
        print_success "🎉 Release $version completed"
    fi
}

main "$@"
