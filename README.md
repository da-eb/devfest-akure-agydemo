# The Zero-Failure Migration: lab repo

DevFest Akure 2026 · David Ebube

This repo is broken on purpose. It's a small FastAPI app carrying the same
problems I found in a real inherited client repo: a hardcoded API key, database
settings that quietly fall back to an old LAN IP, a health route that doesn't
exist, and error handlers that return 200 when something fails.

The pipeline deploys it anyway. The audit is what catches it.

## What you need

- A fork of this repo and a Google Cloud project with Cloud Run enabled
- Antigravity CLI (`agy`):

  ```bash
  curl -fsSL https://antigravity.google/cli/install.sh | bash
  ```

- Sign in once, interactively, before anything else:

  ```bash
  agy
  ```

  `agy -p` (the mode the audit uses) can't open a browser. Skip this step and
  the audit exits with an authentication error.

## Part 1: push a broken repo through a working pipeline

1. Fork and clone this repo.
2. Add these **GitHub Actions secrets** (Settings → Secrets and variables → Actions):

   | Secret | Value |
   |---|---|
   | `GCP_PROJECT_ID` | your project ID |
   | `GCP_SA_KEY` | JSON key for a service account that can deploy to Cloud Run and push images |
   | `APP_ENV` | `staging` |
   | `STORAGE_BUCKET` | any bucket name |

3. Create these in **Secret Manager** in the same project. The workflow mounts them into Cloud Run:
   `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `COMMODITIES_API_KEY`.
   Any placeholder values will do.
4. Push to `main` and watch the workflow.
5. Open `https://<your-service-url>/api/config/check` and compare what the app
   reads with what the workflow set.

## Part 2: run the audit and fix what it finds

```bash
./audit.sh
```

The script hands `app/`, `.github/workflows/` and `app/.env.example` to agy,
which audits them against the rules in `AGENTS.md`. You get a report with
findings, an env var cross-reference and a summary line. If there are any
critical findings, the script exits with 1.

Fix the critical findings in `app/main.py` (hint: start with the API key and
the missing `/health` route), then run `./audit.sh` again until it passes.

Useful flags:

- `./audit.sh --save` writes the report to `audit-report.md`
- `./audit.sh --deps` adds an optional second step: `pip-audit` (or `npm audit`
  in a Node repo) checks dependencies against published advisories, then agy
  says which advisories the app actually reaches

## Part 3: make the rules yours and gate your pushes

1. Open `AGENTS.md`. That's the whole audit: what to look for, how to rate
   it, and what the report looks like.
2. Change one rule to fit your stack and run `./audit.sh` again.
3. Install the pre-push hook:

   ```bash
   ./scripts/setup-hooks.sh
   ```

   From now on `git push` runs the audit first. Any critical finding cancels
   the push; a clean audit lets it through. `--deps` never runs in the hook, so
   a push can't hang waiting on the network.
4. Copy `AGENTS.md` and `audit.sh` into one of your own repos.

## If something goes wrong

| You see | Do this |
|---|---|
| `Antigravity CLI (agy) not found` | Install it (see above) and open a new terminal |
| `authentication required` | Run `agy` once on its own and finish the browser sign-in |
| `headless mode cannot prompt for ... auto-denied` | agy tried to run a shell command. `audit.sh` already gives it the files, so re-run it. Don't add `--dangerously-skip-permissions`: that lets the model run any command on your machine |
| `Could not find the SUMMARY line` | The model didn't follow the report format. Re-run; if it keeps happening, check the output format in `AGENTS.md` |
| You need to push anyway | `git push --no-verify` skips the hook. Use it knowing what you're skipping |

An AI audit is a second pair of eyes, not a guarantee. It reads the code as it
is now. A secret that was ever committed is still in git history, so rotate it
even after you remove it.
