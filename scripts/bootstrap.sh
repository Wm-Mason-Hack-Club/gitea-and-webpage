#!/usr/bin/env bash
# First-time setup: start Gitea, create the admin account, register the CI runner,
# then start everything. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
	cp .env.example .env
	echo "Created .env from .env.example."
	echo "Edit it (at least CLOUDFLARE_TUNNEL_TOKEN), then run this script again."
	exit 1
fi

# Set KEY=VALUE in .env (replace if present, append otherwise).
set_env() {
	local key="$1" value="$2"
	if grep -q "^${key}=" .env; then
		sed -i "s|^${key}=.*|${key}=${value}|" .env
	else
		echo "${key}=${value}" >>.env
	fi
}
get_env() { grep "^$1=" .env | head -n1 | cut -d= -f2-; }

if [[ -z "$(get_env CLOUDFLARE_TUNNEL_TOKEN)" ]]; then
	echo "WARNING: CLOUDFLARE_TUNNEL_TOKEN is empty; the site won't be reachable from the internet"
	echo "         (and the CI runner can't register) until it is set."
fi

mkdir -p data/gitea data/runner

echo "==> Starting Gitea, website and tunnel"
docker compose up -d --build gitea caddy site-sync cloudflared

echo -n "==> Waiting for Gitea to be ready"
until docker compose exec -T gitea curl -fsS http://localhost:3000/api/healthz >/dev/null 2>&1; do
	echo -n "."
	sleep 2
done
echo

gitea() { docker compose exec -T -u git gitea gitea "$@"; }

# ---- Admin account ---------------------------------------------------------
if gitea admin user list --admin 2>/dev/null | awk 'NR>1' | grep -q .; then
	echo "==> Admin account already exists; skipping"
elif [[ -z "${ADMIN_USER:-}" && ! -t 0 ]]; then
	echo "==> No admin account yet, and no terminal to ask. Create one with:"
	echo "    ADMIN_USER=<name> ADMIN_EMAIL=<email> ./scripts/bootstrap.sh"
else
	echo "==> Creating the Gitea admin account (that's you)"
	admin_user="${ADMIN_USER:-}"
	admin_email="${ADMIN_EMAIL:-}"
	[[ -n "$admin_user" ]] || read -rp "    Admin username (not 'admin', it's reserved): " admin_user
	[[ -n "$admin_email" ]] || read -rp "    Admin email: " admin_email
	gitea admin user create --admin \
		--username "$admin_user" --email "$admin_email" \
		--random-password --must-change-password
	echo "    ^ Note the password above. You'll be asked to change it on first login."
fi

# ---- CI runner ---------------------------------------------------------------
if [[ -f data/runner/.runner ]]; then
	echo "==> Runner already registered; skipping"
elif [[ -n "$(get_env RUNNER_REGISTRATION_TOKEN)" ]]; then
	echo "==> Using RUNNER_REGISTRATION_TOKEN from .env"
else
	echo "==> Generating a runner registration token"
	token=$(gitea actions generate-runner-token 2>/dev/null | tail -n1 | tr -d '\r[:space:]')
	set_env RUNNER_REGISTRATION_TOKEN "$token"
fi

echo "==> Starting everything"
docker compose up -d --build

cat <<EOF

Done!
  Website: https://$(get_env SITE_HOST)/
  Gitea:   https://$(get_env GIT_HOST)/

Check status with:  docker compose ps
Runner logs:        docker compose logs -f runner
EOF
