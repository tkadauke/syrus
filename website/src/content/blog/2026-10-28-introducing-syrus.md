---

title: Syrus is out
description: Syrus is a self-hosted orchestrator for coding agents — Claude, Codex, Muse, and Antigravity working from your issue tracker, in parallel, around the clock. Version 0.1.14 is released, and this post explains what it does and why it isn't just another way to run an agent on your laptop.
date: 2026-10-28

---

# Syrus is out

I've been building Syrus since the spring, mostly by having Syrus build itself, and as of this week it's properly out: v0.1.14, open source under MIT, ready to install on your own infrastructure.

Syrus (named after Latin writer [Publilius Syrus](https://en.wikipedia.org/wiki/Publilius_Syrus), whose sayings have outlived him by two millennia) is an orchestrator for coding agents. You file a GitHub issue, or use the built in chat to file a job. Syrus picks it up, runs a coding agent (Claude, Codex, Muse, or Antigravity, using the subscriptions you already pay for) in an isolated workspace, unsupervised, has the work graded and tested, and opens a pull request. You review the PR and approve it, and it lands automatically. Something's off? Leave feedback and Syrus iterates on it. File ten issues and ten of those loops run in parallel. File an issue at midnight and there's a PR waiting when you wake up.

## Why not just run Claude Code on your laptop?

Because I did that first, and it works — for one developer, at one terminal, on one task at a time. A local agent is a conversation. It starts when you sit down and it stops when you close the lid. For a lot of coding that's exactly right, and I'd be the last person to talk you out of it.

Syrus is what I wanted once the work outgrew the conversation:

- **It's a service, not a session.** It runs on a server, not your laptop. Work arrives as issues — from you, from teammates, from a schedule, from an API — and gets done whether or not anyone is watching.
- **The fleet is shared.** With local tools, every developer runs their own private fleet of agents and the team coordinates by hope and standup meetings. Syrus gives the whole team one queue, one set of jobs, one place to look.
- **Parallel work has to land safely.** This turned out to be the actual hard problem. Past about three agents working the same repo, you need machinery: graders that judge a change objectively, test selection, retries against the latest base, and a strict landing queue that serializes merges instead of letting twenty PRs race each other into a red `main`. Syrus is opinionated about all of it, because without it, agent number four is where productivity goes to die. Btw, all of the above is handled deterministically, so no need to yell at your agents every day so they remember to run all the right tests.
- **It doesn't nag.** Inside its workspace, Syrus never asks permission to read a file. It asks before it schedules work, because scheduling spends real resources. That felt like the right boundary, so that's the boundary it has.

However, if you're a solo developer vibe-coding a weekend project, Syrus is overkill and a local agent is the better tool. Syrus makes sense when there are more tasks than terminals — you overflow with ideas, you have a team with a sizeable backlog, or automation that keeps your repository up-to-date.

## It builds itself, by the way

Git was managing its own source code within days of Linus starting it. Tools that make software tend to get turned on themselves almost immediately, and Syrus was no exception — it crossed that line on the first night and never went back. As of an audit in late September, 95.1% of Syrus's merged pull requests had been written by Syrus itself. That's a share of merged PRs, not of every line in the repo, and the methodology and the caveats are written up in the [dogfooding docs](https://syrus-ai.dev/docs/dogfooding) if you want to check my arithmetic. Really the only reason to bypass Syrus is to fix the workflow engine after I break it, which hasn’t happened in a while, and that is the reason I think it’s ready for release.

I mention it because it's still the best evidence I can offer. The core loop gets exercised every day, on a real codebase of over a million lines, more than half of it tests.

## How to get it

There are three basic ways, in increasing order of commitment:

- **The desktop app (Mac).** A DMG download, no terminal involved. It installs the Docker backend for you and puts the full web UI in a native window. This is the five-minute evaluation path.
- **Docker Compose.** The path most teams should take: one command on a Linux box or a Mac, a prebuilt image, SQLite underneath, and the whole loop — web UI, worker, repository polling, PRs.
- **Kubernetes.** The full deployment for larger teams running Syrus on shared infrastructure at scale. It works, but it's the hard-mode path and it will require some tinkering — the Helm chart is still in progress, and the docs are honest about what a cluster deployment needs from you.

The [getting started guide](https://syrus-ai.dev/docs/getting-started) walks through all three, and the [download page](https://syrus-ai.dev/download) has the current release.

## The fine print

It's a 0.1 release. There are rough edges, and you'll find them fastest in large-scale setups and in the more experimental features. The core — issue in, PR out, landed safely — is solid, mostly because it has no choice: it runs my own development.

This blog is where I'll write about what Syrus is teaching me. It's become my testbed for a question I don't think we as an industry have settled yet: what should software development look like when it's designed for a human supervising a fleet of agents, instead of a human typing with an assistant attached? I'll share the experiments, including the ones that fail.

If you run it, please let me know how it goes. Issues and pull requests are welcome — file one, and there's a decent chance an agent will pick it up before I do. Easiest is to use the bug report feature in your instance, it’ll file a Github issue right away.

— Thomas