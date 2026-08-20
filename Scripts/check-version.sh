#!/usr/bin/env bash
# Assert VERSION, CHANGELOG, and an optional tag agree.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
CHANGELOG="$ROOT_DIR/CHANGELOG.md"

die() {
    printf '\033[1;31m[check-version] error:\033[0m %s\n' "$*" >&2
    exit 1
}

project_version="$(tr -d '[:space:]' <"$VERSION_FILE" 2>/dev/null)" \
    || die "could not read $VERSION_FILE"
[[ "$project_version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "VERSION is not stable SemVer: $project_version"

changelog_version="$(sed -nE 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/p' "$CHANGELOG" | head -1)"
[[ -n "$changelog_version" ]] || die "no released version heading found in $CHANGELOG"

[[ "$project_version" == "$changelog_version" ]] \
    || die "VERSION ($project_version) != latest CHANGELOG release ($changelog_version)"
grep -qE "^\[$project_version\]: " "$CHANGELOG" \
    || die "CHANGELOG has no [$project_version] compare-link footer"

if [[ -n "${1:-}" ]]; then
    tag_version="${1#v}"
    [[ "$tag_version" == "$project_version" ]] \
        || die "tag $1 does not match project version $project_version"
fi

printf '\033[1;32m[check-version] OK\033[0m — VERSION and CHANGELOG agree on %s\n' \
    "$project_version"
