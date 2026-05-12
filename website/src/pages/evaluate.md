---
title: Try Syrus locally
description: Run Syrus against your own code in under three minutes with Docker and an Anthropic API key.
---

# Try Syrus locally

Get from "I clicked a link" to "Syrus produced a diff against my code" in
under three minutes. No Ruby install, no database setup, no GitHub
configuration. The evaluation image runs `bin/syrus dev` once against the
Git checkout mounted at `/work`, streams the agent transcript, writes a
three-dot diff, and exits.

## 1. Get an Anthropic API key

Create an API key with Claude access at
[console.anthropic.com](https://console.anthropic.com/), then export it in
the shell where you will run Docker.

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

## 2. Run Syrus against any local repo

From the root of a Git checkout, ask for a small change that should produce
an obvious patch.

```bash
docker run --rm \
  -v "$(pwd):/work" \
  -w /work \
  -e ANTHROPIC_API_KEY \
  ghcr.io/tkadauke/syrus:eval-latest \
  dev /work \
  --prompt "Add a CHANGELOG.md with a placeholder entry for the next release"
```

Syrus copies your checkout into an isolated workflow workspace, runs the
same prepare and implement steps used by the full app, commits the agent's
work locally inside that workspace, and prints the resulting diff.

## 3. Inspect / apply the diff

If the change looks right, rerun with `--output` and apply the saved patch
to your working tree.

```bash
docker run --rm \
  -v "$(pwd):/work" \
  -w /work \
  -e ANTHROPIC_API_KEY \
  ghcr.io/tkadauke/syrus:eval-latest \
  dev /work \
  --prompt "Add a CHANGELOG.md with a placeholder entry for the next release" \
  --output ./syrus.diff && git apply ./syrus.diff
```

## Sample output

Captured from a local fixture run through the same local-dev workflow:
transcript lines first, then the patch Syrus captured from the workflow
workspace.

```text
starting local_dev run 1 step prepare for local/syrus-eval-fixture20260512-7993-j82mtp-e0bb7610#
[prepare] source: .syrus.yml
[prepare] note: prepare: [] — no commands
[prepare] no commands to run; skipping
step prepare done (workflow #1)
starting local_dev run 2 step implement for local/syrus-eval-fixture20260512-7993-j82mtp-e0bb7610#
invoking agent for ad hoc job #1 (workflow #1, step #2 implement)
I'll add a simple changelog file with an unreleased placeholder entry.
● Write(CHANGELOG.md)
  ⎿ Wrote 5 lines to CHANGELOG.md
?? CHANGELOG.md
[syrus/local-1 9be4739] Syrus implement step (will be rewritten by summarize)
 1 file changed, 5 insertions(+)
 create mode 100644 CHANGELOG.md
[workspace] cleanup starting
[workspace] cleanup complete
step implement done (workflow #1)
diff --git a/CHANGELOG.md b/CHANGELOG.md
new file mode 100644
index 0000000..64cef94
--- /dev/null
+++ b/CHANGELOG.md
@@ -0,0 +1,5 @@
+# Changelog
+
+## Unreleased
+
+- Add upcoming release notes here.
```

[Like what you see? Deploy with Docker Compose →](/docs/deployment/docker-compose)

## Troubleshooting

**Docker is not installed or not running.** Install Docker Desktop or Docker
Engine, start it, and rerun the command from a terminal that can execute
`docker`.

**The API key is invalid.** Confirm the key starts with `sk-ant-`, has Claude
access, and is exported in the same shell where Docker runs. The command passes
it through with `-e ANTHROPIC_API_KEY`.

**The container has no internet access.** Syrus needs outbound network access
to call Anthropic and to install dependencies if your repo has a prepare step.
Check VPN, proxy, firewall, and Docker network settings.

**The image will not pull.** Verify the tag is
`ghcr.io/tkadauke/syrus:eval-latest`, then retry after `docker logout
ghcr.io` if Docker is using stale GitHub Container Registry credentials.
