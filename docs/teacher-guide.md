# Teacher Guide

Day-to-day administration of the Hack Club Git server. All commands run from
`~/hack-club-gitea`. Gitea's admin panel is at **your avatar → Site Administration**.

## Student accounts

### Approving sign-ups

Students sign up at `https://git.comet-tech.org/user/sign_up`. New accounts are
inactive until you activate them:

**Site Administration → Identity & Access → User Accounts** → click the user → check
**Is Active** → **Update User Account**.

Tip: ask students to sign up with a recognizable username (e.g. `first-lastinitial`) so
you know whom you're approving.

### Creating accounts yourself (e.g. a whole class)

Turn off self-sign-up by setting `GITEA_DISABLE_REGISTRATION=true` in `.env`, then
`docker compose up -d gitea`. Create accounts from a CSV of `username,email`:

```bash
while IFS=, read -r user email; do
  docker compose exec -T -u git gitea gitea admin user create \
    --username "$user" --email "$email" --random-password --must-change-password
done < roster.csv
```

Each created user and their temporary password is printed; hand them out privately.

### Resetting a password

```bash
docker compose exec -u git gitea gitea admin user change-password \
  --username STUDENT --password 'Temp-Pass-123' --must-change-password
```

### Removing / disabling a student

Site Administration → User Accounts → user → uncheck **Is Active** (keeps their repos),
or **Delete User Account** (they must have no repos/orgs first, or tick *purge*).

## Organizing classes

A good pattern is **one organization per class/section per year**, e.g. `cyber-2026`,
`cs1-p3-2026`, plus `hackclub` for the club.

1. **+ → New Organization** (students can't create orgs; you can).
2. Visibility **Limited** (only signed-in users can see it) or **Private**.
3. Under the org → **Teams**, create a `students` team with **Read** access to
   everything, or no default access and grant it per repo. Add students to the team.

### Assignment templates

1. In the class org, create a repo such as `lab-01-template` with starter code and,
   optionally, an autograding workflow in `.gitea/workflows/` (see
   `examples/workflows/python-tests.yml`).
2. Repo **Settings → Template Repository** ✓.
3. Students click **Use this template** to make their own copy (set owner to themselves
   or the class org, and make it private). Their pushes run the tests automatically and
   you see ✅/❌ in the **Actions** tab.

### Giving students admin-free CI secrets

Repo or org **Settings → Actions → Secrets** lets you store values (API keys, etc.) that
workflows use as `${{ secrets.NAME }}` without students seeing them.

## CI / Actions

- Runner status: **Site Administration → Actions → Runners**.
- Runner logs: `docker compose logs -f runner`.
- Too slow? Raise `capacity:` in `runner/config.yaml` (jobs at once), then
  `docker compose restart runner`. Each job can use up to 2 CPUs / 2 GB RAM.
- Available `runs-on:` values: `ubuntu-latest`, `ubuntu-24.04`, `ubuntu-22.04`.
- Disable Actions for a repo: repo **Settings → Units** → uncheck Actions.
- Clean up disk used by CI images/caches:
  ```bash
  docker compose exec dind docker system prune -af
  ```

### Re-registering the runner

If the runner was deleted in the admin panel or `data/runner` was wiped:

```bash
docker compose stop runner
rm -f data/runner/.runner
sed -i 's/^RUNNER_REGISTRATION_TOKEN=.*/RUNNER_REGISTRATION_TOKEN=/' .env
./scripts/bootstrap.sh
```

## Backups and restores

`./scripts/backup.sh` stops Gitea for a few seconds, snapshots `./data/gitea` (all repos,
the database, attachments, config) to `./backups/gitea-<date>.tar.gz`, restarts Gitea, and
keeps the newest 14. Schedule it nightly with `crontab -e`:

```
0 2 * * * /home/ricec/hack-club-gitea/scripts/backup.sh >> /home/ricec/hack-club-gitea/backups/backup.log 2>&1
```

Copy `./backups/` somewhere off this machine now and then (a school drive, OneDrive via
`/mnt/c/...`, etc.). A backup on the same disk won't help if that disk dies.

**Restoring** (same machine, or a fresh clone of this repo with `.env` copied over):

```bash
docker compose stop gitea
sudo mv data/gitea data/gitea.old          # keep the old copy until you're happy
sudo tar -xzf backups/gitea-XXXXXXXX-XXXXXX.tar.gz -C data
docker compose up -d
```

The runner and website don't need backing up: the runner re-registers
(see above) and the website is re-pulled from Gitea.

## Updating

```bash
git pull                                  # if you changed this repo elsewhere
docker compose pull
docker compose up -d --build
```

Image versions are pinned to a minor release (e.g. `gitea/gitea:1.27`), so `pull` brings
in bug/security fixes but not big upgrades. To move to a new minor version, change the tag
in `docker-compose.yml`, **back up first**, then pull + up.

## Troubleshooting

| Symptom | Check |
|---|---|
| Site shows Cloudflare error 1033 / 502 | `docker compose logs cloudflared` — token wrong, or tunnel's public hostname isn't `http://caddy:80`. |
| Website works but `git.comet-tech.org` gives 502 | `docker compose ps gitea` — is it healthy? `docker compose logs gitea`. Is the `git` public hostname on the tunnel pointing at `http://caddy:80`? |
| `git push` fails with *413* or hangs on big pushes | Cloudflare's free plan limits a single request to 100 MB. Keep large binaries out of git (use releases or Git LFS). |
| `git push` gets HTML/challenge back | Cloudflare Bot Fight Mode or a WAF rule is blocking git. Turn it off for this hostname. |
| Runner never shows up | `docker compose logs runner`. It registers through the public URL, so the tunnel must be working first. |
| Pushed a workflow but no run appears at all | The YAML is invalid, and Gitea skips it without showing an error in the UI. Check `docker compose logs gitea \| grep 'invalid workflow'`. The usual cause is a `: ` inside an unquoted `run:` line; use `run: \|` with the command on the next line. |
| Jobs stuck *Waiting* | `runs-on:` label doesn't match (`ubuntu-latest`, etc.), or the runner is offline. |
| Jobs fail pulling images | `docker compose logs dind`; check the server's internet access / disk space. |
| Website not updating | `docker compose logs site-sync`. The repo must be public (or set `SITE_REPO_TOKEN`), and the branch must match `SITE_BRANCH`. |
| Test without Cloudflare | On this machine: `curl http://127.0.0.1:8088/` (website) and `curl --resolve git.comet-tech.org:8088:127.0.0.1 http://git.comet-tech.org:8088/` (Gitea). Logging in needs the real HTTPS URL. |
