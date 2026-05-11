---
title: Try it locally
description: Run Syrus against any local repo in 60 seconds with a single Docker command.
---

# Try it locally

This path runs Syrus against code that is already on your machine. You do
not install Ruby, create a database, register a GitHub repository, or
open a pull request. Syrus runs once, prints a diff, and exits.

## 1. Get an Anthropic API key

Create an API key with Claude access at
[console.anthropic.com](https://console.anthropic.com/), then export it
in the shell where you will run Docker:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

## 2. Run Syrus against any local repo

From the root of a Git checkout:

```bash
docker run --rm \
  -v "$(pwd):/work" \
  -e ANTHROPIC_API_KEY \
  ghcr.io/tkadauke/syrus:latest dev /work \
  --prompt "Add a CHANGELOG.md with a placeholder entry for the next release"
```

The container starts the Rails app code inside the image, runs
`bin/syrus dev /work --prompt ...`, creates a temporary local-dev Job,
checks out the mounted repo into Syrus's workflow workspace, runs the
standard `prepare -> implement` workflow, captures the three-dot diff,
prints it to stdout, and exits.

## 3. Inspect the diff

Read the diff before applying it. If you want Syrus to write the patch to
a file instead of stdout, pass `--output`:

```bash
docker run --rm \
  -v "$(pwd):/work" \
  -e ANTHROPIC_API_KEY \
  ghcr.io/tkadauke/syrus:latest dev /work \
  --prompt "Add a CHANGELOG.md with a placeholder entry for the next release" \
  --output /work/syrus.diff

git apply syrus.diff
```

## What's not in this path

- No real GitHub polling or issue ingestion.
- No pull request creation.
- No multi-user setup.
- No durable web UI history.
- No persistence between `docker run --rm` invocations.

Use this path to evaluate code-writing behavior. Use Docker Compose when
you want to try the full `issue -> Job -> Workflow -> PR` loop.

## Troubleshooting

**Docker cannot find the image.** Make sure Docker is running and that
the OCI image has been published. The public evaluation command depends
on `ghcr.io/tkadauke/syrus:latest`.

**The command says the path is not a Git work tree.** Run it from inside
a Git checkout. `bin/syrus dev` needs a branch and repository root so it
can compute the same style of diff the full app stores.

**The agent cannot authenticate.** Confirm that `ANTHROPIC_API_KEY` is
set in the same shell and is passed through with `-e ANTHROPIC_API_KEY`.

**The agent fails during setup.** The local-dev workflow still runs the
repo preparation step. If your repo needs private package credentials,
mount or pass only the credentials required for that install.

**The diff is empty.** Syrus completed, but the agent did not make a
change. Try a smaller, more concrete prompt, or ask for a change in a
file that already exists.

**Want the whole product?** Continue to
[Docker Compose](/docs/deployment/docker-compose).
