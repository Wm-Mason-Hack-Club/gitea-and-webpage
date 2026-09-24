#!/bin/sh
# Keeps /site (served by caddy) in sync with a branch of a Gitea repo.
#
# - Until the repo exists, the bundled starter site in /starter is served.
# - If Gitea is briefly unreachable, the last published version stays up.
#
# Env:
#   SITE_REPO_URL    git URL to pull (default: the hackclub/website repo in Gitea)
#   SITE_BRANCH      branch to publish (default: main)
#   SITE_DIR         sub-folder of the repo to publish, e.g. "public" (default: repo root)
#   SITE_REPO_TOKEN  Gitea access token, only needed if the repo is private/limited
#   SYNC_INTERVAL    seconds between checks (default: 60)

set -u

SITE_REPO_URL="${SITE_REPO_URL:-http://gitea:3000/hackclub/website.git}"
SITE_BRANCH="${SITE_BRANCH:-main}"
SITE_DIR="${SITE_DIR:-}"
SYNC_INTERVAL="${SYNC_INTERVAL:-60}"
REPO=/work/repo

log() { echo "[site-sync] $(date '+%Y-%m-%d %H:%M:%S') $*"; }

git_() {
	if [ -n "${SITE_REPO_TOKEN:-}" ]; then
		auth=$(printf '%s:x-oauth-basic' "$SITE_REPO_TOKEN" | base64 | tr -d '\n')
		git -c safe.directory='*' -c http.extraHeader="Authorization: Basic $auth" "$@"
	else
		git -c safe.directory='*' "$@"
	fi
}

publish() {
	src="$1"
	if [ ! -d "$src" ]; then
		log "ERROR: '$src' does not exist (check SITE_DIR); not publishing"
		return 1
	fi
	rsync -a --delete \
		--exclude='.git' --exclude='.gitea' --exclude='.github' \
		"$src"/ /site/
}

last=""
if [ -z "$(ls -A /site 2>/dev/null)" ]; then
	log "no site published yet; serving starter site"
	publish /starter && last="starter"
fi

log "watching $SITE_REPO_URL ($SITE_BRANCH) every ${SYNC_INTERVAL}s"

while :; do
	if git_ ls-remote --exit-code --heads "$SITE_REPO_URL" "$SITE_BRANCH" >/dev/null 2>&1; then
		if [ -d "$REPO/.git" ]; then
			git_ -C "$REPO" remote set-url origin "$SITE_REPO_URL"
			git_ -C "$REPO" fetch --quiet --depth 1 origin "$SITE_BRANCH" \
				&& git_ -C "$REPO" reset --quiet --hard FETCH_HEAD \
				&& git_ -C "$REPO" clean --quiet -fdx
		else
			rm -rf "$REPO"
			git_ clone --quiet --depth 1 --branch "$SITE_BRANCH" "$SITE_REPO_URL" "$REPO"
		fi

		rev=$(git_ -C "$REPO" rev-parse --short HEAD 2>/dev/null || true)
		if [ -n "$rev" ] && [ "$rev" != "$last" ]; then
			if publish "$REPO/${SITE_DIR}"; then
				log "published $rev"
				last="$rev"
			fi
		fi
	fi
	sleep "$SYNC_INTERVAL"
done
