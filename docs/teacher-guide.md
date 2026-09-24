# Teacher Guide

Day-to-day administration of the Hack Club Git server. All commands run from
`~/hack-club-gitea`. Gitea's admin panel is at **your avatar → Site Administration**.

## Student accounts

Only `@masonohioschools.com` email addresses can have accounts (setting:
`GITEA_EMAIL_DOMAIN_ALLOWLIST` in `.env`). This applies to sign-ups **and** to accounts
you create yourself. The address isn't verified by email (there's no mail server), so
**your approval is the real check**. See [Future: email](#future-email).

There are two ways students get accounts.

### Hack Club: students sign up themselves

Students go to `https://git.comet-tech.org/user/sign_up` and use their school email.
They see "You cannot register with your email address" if they use any other address.
New accounts are **inactive** until you activate them:

**Site Administration → Identity & Access → User Accounts** → click the user → check
**Is Active** → **Update User Account**.

Because anyone can *type* a classmate's school email, approve only accounts you can
match to a real student. Having students sign up during a meeting and approving them
right there is the easiest way.

### Classes: create accounts from your roster

Put the roster in `./rosters/` (git-ignored, so student data never goes to GitHub) as a
CSV with a header line:

```csv
username,email,full name
jsmith,jsmith@masonohioschools.com,Jane Smith
bjones,bjones@masonohioschools.com,Bob Jones
```

A simple username scheme is the email's local part. Then:

```bash
./scripts/add-students.sh rosters/cyber-p3.csv
```

Each new account gets a random temporary password, which the student must change at
first login. The passwords are written to `rosters/credentials-<date>.csv` (readable only
by you). Hand them out privately, then **delete that file**. Usernames that already exist
(e.g. a student who's also in Hack Club) are skipped, so re-running a roster is safe.

**Add them to a class team in the same step.** First create the organization and team in
Gitea (see [Organizing classes](#organizing-classes)). Then create an access token under
**your avatar → Settings → Applications → Generate New Token**, with the
*organization: read and write* permission, and run:

```bash
GITEA_TOKEN=<your token> ./scripts/add-students.sh rosters/cyber-p3.csv cyber-2026 students
```

Accounts created this way are already active; no approval needed.

### Outside guests (mentors, a teacher from another district)

The allowlist blocks non-school addresses even for admins. Temporarily add their domain in
`.env` (`GITEA_EMAIL_DOMAIN_ALLOWLIST=masonohioschools.com,gmail.com`), run
`docker compose up -d gitea`, create the account, then remove the domain again and re-run.

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

## Future: email

Without a mail server, Gitea can't verify email addresses or send "forgot password"
links (you reset passwords by hand; see above). Options considered, in order of effort:

1. **SMTP through a transactional email service** (Brevo, Resend, etc.): a free account,
   a few SPF/DKIM DNS records for `comet-tech.org` in Cloudflare, and `GITEA__mailer__*`
   settings. Enables password resets and `REGISTER_EMAIL_CONFIRM`. Note: Gitea can't
   combine email confirmation with manual approval, so you'd trade "teacher approves" for
   "school inbox proves it". Test that district Gmail doesn't mark it as spam.
2. **"Sign in with Google"** (the district uses Google Workspace). Google blocks
   under-18 Workspace for Education accounts from third-party apps unless district IT
   allows the app, so this needs IT's help.

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
