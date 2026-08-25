#!/usr/bin/env bash
# Prepare, validate, and publish a SwiftSpice release.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION_FILE="VERSION"
CHANGELOG="CHANGELOG.md"

log() {
    printf '\033[1;34m[release]\033[0m %s\n' "$*"
}

die() {
    printf '\033[1;31m[release] error:\033[0m %s\n' "$*" >&2
    exit 1
}

version="${1:-}"
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "usage: release.sh X.Y.Z [--yes]"

assume_yes=0
[[ "${2:-}" == "--yes" ]] && assume_yes=1
[[ "${SWIFTSPICE_ASSUME_YES:-0}" == "1" ]] && assume_yes=1
tag="v$version"

log "preflight"
command -v git >/dev/null 2>&1 || die "git is unavailable"
[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty — commit or stash first"
[[ "$(git branch --show-current)" == "main" ]] || die "release must run from main"

git fetch origin main --tags --prune
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
    || die "local main must exactly match origin/main"
if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    die "tag $tag already exists"
fi

"$ROOT_DIR/Scripts/check-version.sh"
current_version="$(tr -d '[:space:]' <"$VERSION_FILE")"
[[ "$version" != "$current_version" \
    && "$(printf '%s\n%s\n' "$current_version" "$version" | sort -V | tail -1)" == "$version" ]] \
    || die "version $version must be greater than $current_version"

unreleased_notes="$(awk '
    /^## \[Unreleased\]/{capture = 1; next}
    /^## \[/{capture = 0}
    capture
' "$CHANGELOG" | grep -v '^[[:space:]]*$' || true)"
[[ -n "$unreleased_notes" ]] \
    || die "CHANGELOG [Unreleased] is empty — add notes for $version first"

base_url="$(sed -nE 's|^\[Unreleased\]: (.*)/compare/.*|\1|p' "$CHANGELOG" | head -1)"
[[ -n "$base_url" ]] || die "could not parse the CHANGELOG compare-link base URL"
release_date="$(date +%F)"

log "preparing $current_version -> $version ($release_date)"
printf '%s\n' "$version" >"$VERSION_FILE"

temporary_changelog="$(mktemp)"
awk -v version="$version" -v date="$release_date" -v previous="$current_version" -v base="$base_url" '
    $0 == "## [Unreleased]" {
        print "## [Unreleased]"
        print ""
        print "## [" version "] — " date
        next
    }
    $0 ~ /^\[Unreleased\]: / {
        print "[Unreleased]: " base "/compare/v" version "...HEAD"
        print "[" version "]: " base "/compare/v" previous "...v" version
        next
    }
    { print }
' "$CHANGELOG" >"$temporary_changelog"
mv "$temporary_changelog" "$CHANGELOG"

"$ROOT_DIR/Scripts/check-version.sh" "$tag"
log "CHANGELOG [Unreleased] -> [$version]"

log "checking build environment"
"$ROOT_DIR/Scripts/doctor.sh"

mkdir -p "$ROOT_DIR/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$ROOT_DIR/.build/module-cache}"

log "verifying generated protocol sources"
swift package --allow-writing-to-package-directory generate-spice-protocol --check

log "analyzing owned C shims"
"$ROOT_DIR/Scripts/analyze-c-shims.sh"

log "building package"
"$ROOT_DIR/Scripts/build-lib.sh"

log "building public API consumer"
swift build --disable-sandbox \
    --package-path Tests/PublicAPIConsumer \
    -Xswiftc -warnings-as-errors

log "running tests"
swift test --disable-sandbox \
    --no-parallel \
    -Xswiftc -warnings-as-errors

log "running AddressSanitizer tests"
"$ROOT_DIR/Scripts/test-address-sanitizer.sh"

log "checking code coverage"
"$ROOT_DIR/Scripts/check-code-coverage.sh"

log "rechecking main and tags after validation"
unexpected_changes="$(git status --porcelain \
    | grep -Ev '^ M (CHANGELOG\.md|VERSION)$' || true)"
[[ -z "$unexpected_changes" ]] \
    || die "validation changed unexpected files:\n$unexpected_changes"
git fetch origin main --tags --prune
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
    || die "origin/main changed during validation — restore release files and rerun"
if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    die "tag $tag was created during validation"
fi

log "prepared $tag at $(git rev-parse --short HEAD)"
git --no-pager diff --stat -- "$VERSION_FILE" "$CHANGELOG"
if [[ "$assume_yes" -ne 1 ]]; then
    printf '\033[1;33mPublish %s — commit version files, push main, and push the tag? [y/N] \033[0m' \
        "$tag" >&2
    read -r reply || reply=n
    case "$reply" in
        y|Y|yes|YES|Yes)
            ;;
        *)
            printf 'Not published. Restore with: git restore %s %s\n' \
                "$VERSION_FILE" "$CHANGELOG" >&2
            exit 0
            ;;
    esac
fi

git add -- "$VERSION_FILE" "$CHANGELOG"
git commit -m "Release $version"
git push origin main
git tag -a "$tag" -m "SwiftSpice $version"
log "pushing $tag"
git push origin "$tag"
log "release workflow started: https://github.com/BeriBeli/spice-swift/actions"
