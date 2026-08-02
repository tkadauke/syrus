---
title: FAQ
description: Frequently-asked questions about Syrus.
---

# FAQ

## How is Syrus different from Devin?

Devin is a hosted coding-agent product. Syrus is self-hosted,
MIT-licensed, and bring-your-own-key. You run it on your infrastructure,
store the credentials, keep the audit trail, and decide which model
provider each user or repository uses.

That makes Syrus less polished than a managed SaaS, but much easier to
reason about if your main questions are "where does my code go?" and
"who can see the transcript?"

## How is Syrus different from OpenHands?

OpenHands is a full agent environment with its own agent loop. Syrus is a
thin orchestrator around existing coding CLIs such as `claude-code` and
Codex. Syrus owns the deterministic parts: polling, cloning, branches,
Workflows, PRs, cleanup, transcripts, and retries.

Syrus is also multi-tenant from day one. Users bring their own GitHub and
agent credentials, and one deployment can coordinate work across many
repositories without becoming a single-user desktop tool.

## How is Syrus different from Anthropic's claude-code-action?

`claude-code-action` is a GitHub Action installed per repository. It is a
good fit when one repo needs a lightweight `@claude` flow.

Syrus centralizes state outside GitHub Actions. It polls GitHub instead
of receiving inbound callbacks, works across repositories from one deployment,
keeps Job and Run history in its own database, supports scheduled and
ad-hoc Jobs, and does not require installing a workflow file in every
repo.

## How is Syrus different from GitHub Copilot Coding Agent?

Copilot Coding Agent is GitHub-hosted and tied to GitHub's product,
identity, billing, and model choices. Syrus is self-hostable and BYOK.
You can run it against GitHub repositories today without handing the
orchestration layer to github.com.

Syrus is not trying to beat GitHub on native platform integration. It is
for teams that want the issue-to-PR loop while still owning deployment,
credentials, data retention, and model choice.

## What does Syrus cost?

Syrus itself is free and MIT-licensed. Your real cost is the model bill:
Anthropic for Claude runs, OpenAI for Codex runs, or whatever provider a
future adapter uses.

You also pay your own infrastructure cost. For a small team, that can be
a Docker Compose box. For a production deployment, it is your database,
worker, web process, and persistent clone/workspace storage.

## Is the agent safe to give my repo access?

Treat it like giving a powerful developer access to the repo and a shell.
Syrus creates per-Workflow workspaces outside the application checkout and
pushes through your GitHub token, but the current agent invocation is
intentionally capable: it can read and edit the checkout and run commands
needed to complete the task. The MVP assumes trusted users and trusted
repositories; the workspace is not a hardened untrusted-code sandbox.

The roadmap includes stronger sandboxing and policy controls, including
disposable containers per Run and tighter boundaries around what the
agent can reach. Until those land, run Syrus in infrastructure you trust,
use scoped GitHub tokens, keep secrets out of repositories, and review
PRs like you would review work from a human contributor.

## Can I use a model other than Claude?

Yes. Syrus has provider abstractions and supports Codex in addition to
Claude. Users choose a default provider for Jobs and future chats; repositories
can override Job provider selection, and retry actions can use any provider the
user has configured.

Community providers are possible as long as they can fit the same shape:
run in a workspace, stream logs, return a result, and let Syrus capture
the transcript and diff.

## Do you offer a hosted version?

No. Syrus is self-host-first by design. A hosted version would change the
trust model: the operator would hold user code, model credentials,
transcripts, and GitHub tokens. That is not the project this is trying to
be.

## Why polling instead of inbound callbacks?

Polling is less fashionable and much easier to operate. Syrus does not
need a public ingress endpoint, callback secret rotation, delivery replay
handling, or per-repo callback installation. The worker asks GitHub what
changed and records what it did.

The trade-off is latency. Most automation runs on the next poll tick
instead of instantly. For this kind of background coding work, that is
usually the right trade.

## Does Syrus work without GitHub?

Not today. The current product is GitHub-native: issues, labels, PRs,
reviews, checks, and branches all flow through GitHub APIs.

The internal model is not inherently GitHub-only, but other forges would
need adapters for repository registration, issue ingestion, comments,
checks, and PR creation.

## Can Syrus run scheduled maintenance?

Yes. Scheduled tasks can run recurring cron prompts or one-shot prompts
against a repository. They use the same Job, Workflow, Step, and Run
pipeline as issue-driven work.

Scheduled prompts should be conservative. Ask the agent to inspect a
specific area and explicitly allow "no changes" as a successful result.

## Can Syrus respond to PR feedback and failing CI?

Yes. For PRs attached to open Syrus Jobs, Syrus polls for new review
comments and failed GitHub Checks. Review feedback creates a
`pr_comment` Workflow; failed checks create a `ci_failure` Workflow.
Both push follow-up commits to the same branch.

## What happens when the agent makes no change?

For issue Jobs, no diff usually means no PR opens. The transcript should
explain whether the agent found nothing to do, hit a setup problem, or
failed to understand the prompt.

For scheduled Jobs, no diff can be the expected happy path. Syrus treats
"no useful change today" as a valid outcome when the agent reports that
clearly.

## Where did the name come from?

See [About](/about). Short version: the name points at Publilius Syrus,
whose "quick help counts twice" line fits an issue-to-PR automation tool
well enough that the joke became load-bearing.
