# Notes for AI assistants

Context for any AI agent (Claude Code, Copilot, Codex, etc.) working on this repo.
Humans: the [README](README.md) and [teacher guide](docs/teacher-guide.md) are for you.

## What this is

A high school teacher's self-hosted Git platform for the **Wm. Mason High School Hack Club**
and their **CS and Cybersecurity classes**. Users are **students, mostly minors**. The
teacher is the only admin. They're technical but busy, so prefer simple, low-maintenance
solutions, and talk trade-offs through before building anything big.

- GitHub (tracks this config): `git@github.com:Wm-Mason-Hack-Club/gitea-and-webpage.git`
- Server: `~/hack-club-gitea` on the teacher's WSL2 machine (Docker 28, Compose v2)
- **This is live production.** Students' work lives here.

## Architecture

```
Cloudflare ─► cloudflared ─► caddy ─┬─ git.comet-tech.org  ─► gitea:3000
  (1 tunnel, 2 routes,              └─ hack.comet-tech.org ─► /srv/site (static)
   both → http://caddy:80)                                        ▲
                                  site-sync: pulls hackclub/website from Gitea every 60s
runner (act_runner) ─► dind   (CI jobs run in dind, on the `ci` network only)
```

| Service | Notes |
|---|---|
| `gitea` | `gitea/gitea:1.27`, SQLite, data in `./data/gitea`. Configured entirely by `GITEA__section__KEY` env vars in `docker-compose.yml`; don't hand-edit `app.ini`. |
| `caddy` | Routes by `Host`. TLS ends at Cloudflare, so Caddy is plain HTTP. Also on `127.0.0.1:8088` for local testing. |
| `site-sync` | The only custom image (`site-sync/`). Serves `./website` until the `hackclub/website` repo exists, and keeps the last good version if Gitea is down. |
| `cloudflared` | Token in `.env` (`CLOUDFLARE_TUNNEL_TOKEN`). Routes are managed in the Cloudflare dashboard, not here. |
| `runner` | `gitea/act_runner:0.6`. Registers via the **public** URL. Config in `runner/config.yaml`. |
| `dind` | `docker:29-dind`, privileged. Holds all CI containers and images. |

## Decisions and why (don't undo these without asking)

- **Gitea on its own hostname, not a `/git` path.** The teacher chose this. (A
  two-level subdomain like `git.hack.comet-tech.org` would not be covered by Cloudflare's
  free certificate.)
- **One tunnel, both routes → `http://caddy:80`.** Never `localhost:*`: inside the
  cloudflared container, localhost is cloudflared itself (this caused 502s at launch).
- **No SSH.** It doesn't pass through a plain tunnel. Git uses HTTPS + access tokens.
- **CI isolation is a security requirement** (Cybersecurity students write workflows).
  Jobs run in `dind`, never on the host's Docker. They're on the `ci` network, which can't
  reach gitea/caddy, so they reach Gitea through the public URL. They get no Docker socket
  (`docker_host: "-"`), no volumes, aren't privileged, and are capped at 2 CPU / 2 GB /
  1024 PIDs / 1 h. Don't mount `/var/run/docker.sock` anywhere.
- **Accounts:** only `@masonohioschools.com` addresses (`EMAIL_DOMAIN_ALLOWLIST`, which
  Gitea also enforces for admin-created accounts). Self-sign-ups need manual teacher
  approval, plus CAPTCHA. Class students are bulk-created with `scripts/add-students.sh`.
  There's **no mail server**, so emails aren't verified; the teacher's approval is the
  real check. Future email options are in the teacher guide ("Future: email").
- **Student privacy defaults:** users and orgs visible only to signed-in users, emails
  hidden, repos private by default, students can't create orgs. Keep it that way.
- **SQLite** is plenty for this scale, and backups are a tarball of `./data/gitea`.

## Gotchas found the hard way

- **dind's TLS certificate is only valid for the hostname `docker`.** dind has the network
  alias `docker`, and the runner uses `DOCKER_HOST=tcp://docker:2376`. Using `dind:2376`
  fails x509 verification.
- **A workflow with invalid YAML is silently ignored**: no run, and no error in the web
  interface. Check `docker compose logs gitea | grep 'invalid workflow'`. Common cause: `: `
  inside an unquoted `run:` line.
- **Job containers can't resolve compose service names** like `gitea`. That's by design,
  since jobs use the public URL. Keep `container.network: ""` in `runner/config.yaml`:
  dind's default `bridge` network has no working DNS (localhost resolvers get filtered).
- **WSL2 uses cgroup v1**, so `/sys/fs/cgroup/memory.max` doesn't exist inside jobs. To
  verify limits, look at `Merged container.HostConfig` in the job log.
- **Gitea's CLI has no "edit user" command.** Promoting or activating an existing user
  means a web UI change, or SQLite: `docker compose exec -u git gitea sqlite3
  /data/gitea/gitea.db "UPDATE user SET ... WHERE lower_name='x';"`.
- **`gitea admin` commands must run as the `git` user**: `docker compose exec -u git gitea gitea ...`.
- **Gitea makes the first user on a fresh server an admin.** Irrelevant in production
  (admin `ricec` exists), but it surprises you in test instances.

## Current state (as of 2026-09-24)

Done and verified: both hostnames are live through Cloudflare. The runner is registered,
and a live CI run passed (checkout, setup-python, pytest, secrets, cache, artifacts). The
teacher's admin account `ricec` exists. The domain allowlist is on.

Not done yet:
- The `hackclub/website` repo hasn't been created in Gitea, so the starter site from
  `./website` is being served (README step 4).
- No backup cron job, and no backups taken yet (`scripts/backup.sh`; cron line in the
  teacher guide).
- The website has placeholder meeting day/room (`website/index.html` TODO).

## Working on this safely

- **Never commit secrets or student data.** `.env`, `data/`, `backups/` and `rosters/`
  are git-ignored. Before committing, run `git grep --cached -lE 'eyJhIjoi[A-Za-z0-9+/=]{40,}'` (the tunnel
  token prefix); it should print nothing.
- **Test changes on a throwaway instance, not production.** For example, run
  `docker run -d --rm --name gitea-test -p 127.0.0.1:3999:3000 -e GITEA__security__INSTALL_LOCK=true
  -e GITEA__database__DB_TYPE=sqlite3 ... gitea/gitea:1.27`. `scripts/add-students.sh` accepts
  `GITEA_CONTAINER=` and `GITEA_URL=` to point at one.
- If you must test on production, use clearly named temporary accounts (e.g.
  `ci-smoketest`), delete them with `gitea admin user delete --username X --purge`, and tell
  the teacher.
- Restarting `gitea` means a few seconds of downtime. Say so before doing it during school
  hours.
- Validate Caddy changes with `docker run --rm -e SITE_HOST=... -e GIT_HOST=...
  -v $PWD/caddy/Caddyfile:/etc/caddy/Caddyfile:ro caddy:2.11-alpine caddy validate
  --config /etc/caddy/Caddyfile`, and compose changes with `docker compose config -q`.
- Push to GitHub over SSH (the key is set up; HTTPS has no saved login). Commit with the
  teacher's configured git identity.
- Keep the README (setup, overview) and `docs/teacher-guide.md` (day-to-day admin) up to
  date when behavior changes, and update "Current state" above.
