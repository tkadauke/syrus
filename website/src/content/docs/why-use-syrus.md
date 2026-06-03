---
title: Why use Syrus?
description: Reasons to run Syrus: self-hosting, BYOK credentials, multi-user operation, and auditable agent work.
---

# Why use Syrus?

Syrus exists for teams that want agentic coding help without moving their
code, credentials, transcripts, and operational control into a hosted
black box.

## You own the keys

Users bring their own GitHub and agent credentials. Syrus stores them with
Active Record Encryption, uses them to perform work for that user, and keeps
push credentials out of clone remotes.

That means credential scope, token rotation, model-provider access, and
audit retention remain operator decisions.

## You self-host the harness

Syrus runs as a Rails app with a web process, worker process, database, and
durable workspace storage. You can start with Docker Compose and move to
Kubernetes when you need cluster operations.

Because Syrus polls GitHub instead of receiving inbound webhooks, small
self-hosted deployments do not need to expose a public callback endpoint
just to try the product.

## It is multi-user from day one

One Syrus instance can coordinate many users and repositories. Each user
has their own credentials and agent preferences. Repositories can override
the default provider when a repo needs a different agent.

The result is closer to an internal automation system than a single-user
desktop tool.

## The transcript is part of the product

Every Run records what happened: prompt, transcript, agent metadata, diff,
PR copy, state transitions, and logs. Operators can inspect a Job, retry a
failed Workflow, cancel work that is going the wrong way, and follow the PR
Syrus opened.

This matters because agent work is probabilistic. The harness should make
the surrounding system boring, observable, and recoverable.

## The normal review process stays in charge

Syrus opens pull requests. It does not bypass code review, branch
protection, CI, or merge policy. The recommended operating model is simple:
let Syrus prepare a candidate change, then review and merge it the same way
you would review a human-authored PR.

Next: [Getting Started](/docs/getting-started) helps you pick an evaluation
or deployment path.
