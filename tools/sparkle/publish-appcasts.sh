#!/bin/bash
set -euo pipefail

tag="${1:?Pass the release tag}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
scripts="$(cd "$(dirname "$0")" && pwd)"
repo=xiheha3213906313/opendisplay
branch=sparkle-feeds
ref="refs/heads/$branch"

if [[ "$(gh api "repos/$repo/releases/latest" --jq .tag_name)" != "$tag" ]]; then
    echo "Keeping the existing appcasts. $tag is not the latest stable release."
    exit 0
fi
git fetch --no-tags origin "refs/tags/$tag"
if ! git show FETCH_HEAD:project.yml | grep -F "raw.githubusercontent.com/$repo/$branch/" >/dev/null; then
    echo "Keeping the existing appcasts. $tag predates this update channel."
    exit 0
fi

stage="$(mktemp -d)"
tree="$stage/feeds"
cleanup() {
    if [[ -d "$tree" ]]; then git worktree remove --force "$tree"; fi
    rm -rf "$stage"
}
trap cleanup EXIT

published="$(git ls-remote --heads origin "$ref")"
if [[ -n "$published" ]]; then
    git fetch --no-tags origin "$ref"
    git worktree add --detach "$tree" FETCH_HEAD
    if ! ruby -rrubygems -e 'exit(Gem::Version.new(ARGV[0]) > Gem::Version.new(ARGV[1]))' \
        "${tag#v}" "$(cat "$tree/release-version")"; then
        echo "Already published $(cat "$tree/release-version")."
        exit 0
    fi
else
    git worktree add --detach "$tree" HEAD
    git -C "$tree" switch --orphan "$branch"
fi

: "${SPARKLE_SENDER_PUBLIC_KEY:?Configure the sender public key}"
: "${SPARKLE_RECEIVER_PUBLIC_KEY:?Configure the receiver public key}"
if [[ "$SPARKLE_SENDER_PUBLIC_KEY" == "$SPARKLE_RECEIVER_PUBLIC_KEY" ]]; then
    echo "Use distinct Sparkle keys for the two products." >&2
    exit 1
fi

bash "$scripts/install-tools.sh" "$stage/sparkle"
SPARKLE_PUBLIC_KEY="$SPARKLE_SENDER_PUBLIC_KEY" SPARKLE_PRIVATE_KEY="$SPARKLE_SENDER_PRIVATE_KEY" \
    bash "$scripts/make-appcast.sh" "$stage/sparkle" "$tag" sender "$stage"
SPARKLE_PUBLIC_KEY="$SPARKLE_RECEIVER_PUBLIC_KEY" SPARKLE_PRIVATE_KEY="$SPARKLE_RECEIVER_PRIVATE_KEY" \
    bash "$scripts/make-appcast.sh" "$stage/sparkle" "$tag" receiver "$stage"

for feed in appcast.xml appcast-receiver.xml; do
    if [[ -f "$tree/$feed" ]]; then
        version_xpath='string(//item/*[local-name()="version"])'
        previous="$(xmllint --xpath "$version_xpath" "$tree/$feed")"
        next="$(xmllint --xpath "$version_xpath" "$stage/$feed")"
        [[ "$previous" =~ ^[1-9][0-9]*$ && "$next" =~ ^[1-9][0-9]*$ && "$next" -gt "$previous" ]]
    fi
    cp "$stage/$feed" "$tree/$feed"
done
printf '%s\n' "${tag#v}" > "$tree/release-version"
git -C "$tree" add appcast.xml appcast-receiver.xml release-version
git -C "$tree" -c user.name='github-actions[bot]' \
    -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit -m "Publish Mac appcasts for $tag"
git push origin "$(git -C "$tree" rev-parse HEAD):$ref"
