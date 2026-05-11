---
title: Try Syrus locally
description: Run Syrus against your own code in 60 seconds — no installation, no GitHub setup.
---

<!-- STUB. See docs/plans/website.md § "The 3-step 'Try it locally'
     page" for the intended flow.

     Implementation issue: "3-step 'Try it locally' eval page."
     Depends on the OCI image (separate issue).

     Content brief:
     - 3 commands, exactly. No more.
     - Show a sample stdout afterward (formatted diff + a few lines
       of transcript) so visitors know what success looks like
     - Link at the bottom: "Like what you see? Deploy with Docker
       Compose →" pointing at /docs/deployment/docker-compose
     - Mention this uses `bin/syrus dev` from PR #188
-->

# Try Syrus locally

Get from "I clicked a link" to "Syrus produced a diff against my
code" in under three minutes. No Ruby install, no database setup,
no GitHub configuration.

## 1. Get an Anthropic API key

You'll need an Anthropic API key with Claude access. Get one at
[console.anthropic.com](https://console.anthropic.com/).

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

## 2. Run Syrus against any local repo

```bash
docker run --rm \
  -v $(pwd):/work \
  -e ANTHROPIC_API_KEY \
  ghcr.io/tkadauke/syrus:latest dev /work \
  --prompt "Add a CHANGELOG.md with a placeholder entry for the next release"
```

The container clones your working tree, runs the agent against it
synchronously, and writes the resulting diff to stdout.

## 3. Inspect the diff

Review what Syrus produced. If you like it:

```bash
docker run --rm -v $(pwd):/work ghcr.io/tkadauke/syrus:latest \
  dev /work --prompt "..." --output ./syrus.diff
git apply ./syrus.diff
```

---

**Like what you see?** [Deploy Syrus with Docker Compose →](/docs/deployment/docker-compose)
