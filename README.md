# Hack Club Git Server

A self-hosted setup for the Hack Club and the CS / Cybersecurity classes:

| What | Where |
|---|---|
| Club website | `https://hack.comet-tech.org/` |
| Gitea (git hosting, issues, pull requests) | `https://git.comet-tech.org/` |
| CI/CD (Gitea Actions, works like GitHub Actions) | built into Gitea |

Everything runs in Docker on one machine and reaches the internet through a
**Cloudflare Tunnel**, so no ports are opened on the school network and Cloudflare handles HTTPS.

```
                    ┌──────────────────────────── this server (docker compose) ─────────────────────────────┐
Browser / git ──►   │ cloudflared ──► caddy ─┬─ git.comet-tech.org  ──► gitea ◄── site-sync (pulls website) │
 (Cloudflare)       │                        └─ hack.comet-tech.org ──► website files ◄───┘                 │
                    │                                                                                       │
                    │ runner ──► dind   (CI jobs run in their own Docker, never the host's)                 │
                    └───────────────────────────────────────────────────────────────────────────────────────┘
```

| Service | Image | Job |
|---|---|---|
| `gitea` | `gitea/gitea:1.27` | Git hosting. SQLite database, data in `./data/gitea`. |
| `caddy` | `caddy:2.11-alpine` | Routes by hostname: `git.` → Gitea, `hack.` → the website. |
| `site-sync` | built from `./site-sync` | Every 60 s, pulls the `hackclub/website` repo from Gitea and publishes it. |
| `cloudflared` | `cloudflare/cloudflared` | The Cloudflare Tunnel connector. |
| `runner` | `gitea/act_runner:0.6` | Picks up CI jobs from Gitea. |
| `dind` | `docker:29-dind` | A private Docker daemon that CI jobs run in. |

---

## Setup

### 1. Prerequisites

- Docker + Docker Compose v2 on this server (already installed).
- Access to the Cloudflare Zero Trust dashboard for `comet-tech.org`.

### 2. Create a Cloudflare Tunnel

This stack runs its own tunnel connector, separate from the one used by `code-server-host`.
One tunnel serves both hostnames; Caddy tells them apart.

1. Cloudflare dashboard → **Zero Trust** → **Networks** → **Tunnels** → **Create a tunnel**.
2. Pick **Cloudflared**, name it (e.g. `hackclub`).
3. On the install screen choose **Docker**, and copy the long token after `--token`.
   (You don't need to run their command; compose does it.)
4. Add two **Public Hostnames**, both pointing at the same service:

   | Subdomain | Domain | Path | Service |
   |---|---|---|---|
   | `hack` | `comet-tech.org` | *(empty)* | **HTTP** → `caddy:80` |
   | `git` | `comet-tech.org` | *(empty)* | **HTTP** → `caddy:80` |

5. Save. Cloudflare creates the DNS records for you.

> **Use `caddy:80`, not `localhost`.** The tunnel connector runs in its own container,
> where `localhost` means the connector itself. Routes like `http://localhost:3000` give a
> 502 error and `cloudflared` logs `dial tcp [::1]:3000: connect: connection refused`.

> If either hostname is already routed somewhere else (e.g. by the existing tunnel),
> remove it there first. One hostname can only point at one tunnel.

**Recommended Cloudflare settings** (Security section for `comet-tech.org`):
leave **Bot Fight Mode** off, or `git push` and the CI runner can get blocked by challenges.

### 3. Configure and start

```bash
cd ~/hack-club-gitea
cp .env.example .env
nano .env                  # paste CLOUDFLARE_TUNNEL_TOKEN; check SITE_HOST / GIT_HOST
./scripts/bootstrap.sh
```

`bootstrap.sh` will:

1. start Gitea, Caddy, site-sync and the tunnel,
2. ask for **your** admin username + email and print a one-time password,
3. generate a CI runner registration token and save it in `.env`,
4. start everything else (runner + dind).

Then open `https://git.comet-tech.org/`, sign in, and set a new password.

Check that everything is healthy:

```bash
docker compose ps
docker compose logs -f runner     # should say "runner: hackclub-runner-1 ... declared successfully"
```

Site Administration → **Actions** → **Runners** in Gitea should list the runner as *Idle*.

**Check that CI works end to end:** create a test repo, add
[`examples/workflows/hello.yml`](examples/workflows/hello.yml) as `.gitea/workflows/hello.yml`,
and push. The repo's **Actions** tab should show a green run within a minute.

### 4. Put the website under Gitea

Until this step, the starter site from `./website` is shown.

1. In Gitea: **+** → **New Organization** → name it `hackclub`, visibility **Public**.
2. In that org: **New Repository** → name `website`, **uncheck "Make repository private"**.
3. Push the starter site into it:

   ```bash
   cd ~/hack-club-gitea/website
   git init -b main
   git add -A && git commit -m "Starter site"
   git remote add origin https://git.comet-tech.org/hackclub/website.git
   git push -u origin main    # username + password (or an access token)
   ```

Within a minute, `site-sync` picks it up (`docker compose logs site-sync` shows
`published <commit>`). From now on, **anything merged to `main` in `hackclub/website` goes live**.
The repo includes a CI workflow (`.gitea/workflows/check.yml`) that validates the HTML and
checks for broken links on every push and PR, so students can open PRs and see a ✅/❌.

To let club officers merge website changes, add them to a team in the `hackclub` org
with write access to the repo, and set up branch protection on `main` if you want
reviews required.

> Using a static site generator (Hugo, Astro, Jekyll...)? Have a workflow build it and
> push the output to a `pages` branch, then set `SITE_BRANCH=pages` in `.env` and run
> `docker compose up -d site-sync`. Or commit the build output and set `SITE_DIR=public`.

---

## Using it

### For students

- **Sign up** at `https://git.comet-tech.org/user/sign_up`. Accounts stay inactive
  until you approve them (see [docs/teacher-guide.md](docs/teacher-guide.md)).
- **Cloning / pushing uses HTTPS**, not SSH (SSH doesn't pass through the tunnel):
  ```bash
  git clone https://git.comet-tech.org/<user>/<repo>.git
  ```
  Git will ask for a username and password. If you'd rather not type it, create a token
  under **Settings → Applications → Access Tokens** (scope: `repository` read & write) and
  use the token as the password.
- **CI**: put a workflow file in `.gitea/workflows/` in any repo. See
  [`examples/workflows/`](examples/workflows/) for Python, C/C++ and a hello-world.
  The syntax is the same as GitHub Actions; `actions/checkout@v4` etc. work.
  Results show up in the repo's **Actions** tab. Store API keys and passwords under
  repo **Settings → Actions → Secrets**; they're masked as `***` in logs.

### Everyday admin commands

```bash
docker compose ps                        # what's running
docker compose logs -f gitea             # follow logs (gitea, caddy, runner, site-sync, cloudflared)
docker compose restart gitea
docker compose pull && docker compose up -d --build   # update to the latest images
./scripts/backup.sh                      # back up Gitea to ./backups/ (few seconds of downtime)
```

More in [docs/teacher-guide.md](docs/teacher-guide.md): approving accounts, class
organizations, assignment templates, resetting passwords, backups, restores and
troubleshooting.

---

## Security notes

This is a server that students — including Cybersecurity students — will poke at.
Choices made on purpose:

- **Nothing is exposed except through the tunnel.** Caddy's port is bound to
  `127.0.0.1` for local testing only. Gitea, the runner and dind have no published ports.
- **CI jobs are sandboxed from the host.** Jobs run inside the `dind` container's
  Docker, on a separate `ci` network that can't reach Gitea, Caddy or anything else
  on the server. They reach Gitea the same way students do, through the public URL. Jobs can't
  mount volumes, don't get a Docker socket, aren't privileged, and are capped at
  2 CPUs / 2 GB RAM / 1 h each ([runner/config.yaml](runner/config.yaml)).
  `dind` itself must run `privileged`, so it's a strong boundary but not a perfect one.
  If you ever need stronger isolation, run the runner on a separate VM.
- **Accounts need teacher approval**, sign-up has a CAPTCHA, and students can't create
  organizations.
- **Student privacy:** new users and orgs default to *limited* visibility (only visible to
  signed-in users), emails are hidden, and new repos default to private. Anonymous
  visitors only see things that were explicitly made public.
- **Secrets** live only in `.env` (git-ignored). Don't commit it.

## Running on WSL2

This server is WSL2. Containers restart automatically only while the WSL VM and Docker
are running, so make sure WSL starts with Windows and the PC doesn't sleep. Everything
lives under `~/hack-club-gitea` on the Linux filesystem (not `/mnt/c`), which keeps Git
and SQLite fast.

## Repo layout

```
docker-compose.yml        all services
.env.example              settings template (copy to .env)
caddy/Caddyfile           routing: git. -> Gitea, hack. -> website
runner/config.yaml        CI runner settings, job limits, runs-on labels
site-sync/                Dockerfile + script that publishes the website repo
website/                  starter club website (push this into hackclub/website)
examples/workflows/       sample CI workflows for student repos
scripts/bootstrap.sh      first-time setup
scripts/backup.sh         Gitea backups
docs/teacher-guide.md     day-to-day administration
data/                     (git-ignored) Gitea + runner data — this is what to back up
```
