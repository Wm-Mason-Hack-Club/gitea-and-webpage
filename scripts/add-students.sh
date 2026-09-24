#!/usr/bin/env bash
# Bulk-create student accounts from a roster CSV, optionally adding them to a class team.
#
# Usage:
#   scripts/add-students.sh rosters/cyber-p3.csv
#   GITEA_TOKEN=<admin token> scripts/add-students.sh rosters/cyber-p3.csv cyber-2026 students
#
# Roster CSV (keep it in ./rosters/, which is git-ignored — it's student data):
#   username,email,full name
#   jsmith,jsmith@masonohioschools.com,Jane Smith
# A header line and lines starting with # are skipped. Full name is optional.
#
# New accounts get a random temporary password (must be changed at first login),
# written to rosters/credentials-<date>.csv. Hand them out, then delete that file.
# Existing usernames are skipped, so re-running a roster is safe.
#
# Adding to a team needs an admin access token with write:organization scope:
# your avatar -> Settings -> Applications -> Generate New Token.
# The org and team must already exist.
set -euo pipefail
cd "$(dirname "$0")/.."

roster="${1:-}"
org="${2:-}"
team="${3:-}"
if [[ -z "$roster" || ! -f "$roster" ]] || [[ -n "$org" && -z "$team" ]]; then
	sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
	exit 1
fi

# Overridable for testing against another instance.
GITEA_URL="${GITEA_URL:-https://$(grep '^GIT_HOST=' .env | cut -d= -f2-)}"
gitea() {
	if [[ -n "${GITEA_CONTAINER:-}" ]]; then
		docker exec -u git "$GITEA_CONTAINER" gitea "$@" </dev/null
	else
		docker compose exec -T -u git gitea gitea "$@" </dev/null
	fi
}
api() {
	curl -fsS -H "Authorization: token $GITEA_TOKEN" -H 'Accept: application/json' "$@"
}

team_id=""
if [[ -n "$team" ]]; then
	: "${GITEA_TOKEN:?Set GITEA_TOKEN to an admin access token to add students to a team}"
	team_id=$(api "$GITEA_URL/api/v1/orgs/$org/teams" |
		python3 -c 'import sys,json; t=[x["id"] for x in json.load(sys.stdin) if x["name"].lower()==sys.argv[1].lower()]; print(t[0] if t else "")' "$team")
	if [[ -z "$team_id" ]]; then
		echo "Team '$team' not found in org '$org'. Create it in Gitea first." >&2
		exit 1
	fi
fi

mkdir -p rosters
creds="rosters/credentials-$(date +%Y%m%d-%H%M%S).csv"
(umask 077; echo "username,email,temporary_password" >"$creds")

created=0 skipped=0 failed=0
while IFS=, read -r user email name <&3 || [[ -n "${user:-}" ]]; do
	user=$(echo "$user" | tr -d '\r' | xargs)
	email=$(echo "${email:-}" | tr -d '\r' | xargs)
	name=$(echo "${name:-}" | tr -d '\r' | xargs)
	[[ -z "$user" || "$user" == \#* || "$user" == username ]] && continue

	args=(admin user create --username "$user" --email "$email" --random-password --must-change-password)
	[[ -n "$name" ]] && args+=(--fullname "$name")

	if out=$(gitea "${args[@]}" 2>&1); then
		pass=$(echo "$out" | sed -n "s/.*generated random password is '\(.*\)'.*/\1/p")
		echo "$user,$email,$pass" >>"$creds"
		echo "created  $user"
		created=$((created + 1))
	elif echo "$out" | grep -qi 'already exist'; then
		echo "exists   $user"
		skipped=$((skipped + 1))
	else
		echo "FAILED   $user: $(echo "$out" | tail -n1)"
		failed=$((failed + 1))
		continue
	fi

	if [[ -n "$team_id" ]]; then
		api -X PUT "$GITEA_URL/api/v1/teams/$team_id/members/$user" -o /dev/null &&
			echo "         + added to $org/$team" ||
			echo "         ! could not add $user to $org/$team"
	fi
done 3<"$roster"

echo
echo "Created $created, already existed $skipped, failed $failed."
if [[ $created -gt 0 ]]; then
	echo "Temporary passwords: $creds  (hand them out, then delete the file)"
else
	rm -f "$creds"
fi
