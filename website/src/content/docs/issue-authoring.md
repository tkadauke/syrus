---
title: Issue Authoring
description: File GitHub issues that Syrus can ingest as Jobs, Epics, and dependency-ordered work.
---

# Issue Authoring

Syrus can turn GitHub issues into Jobs and Epics when the repository is
registered, polling is enabled, and the issue carries the repository's
trigger label. The default trigger label is `syrus`, but each repository can
choose a different label.

Issue ingestion is polling-based, not webhook-based. Repository issue polls,
PR feedback polls, merge-state polls, and most GitHub sync jobs run about
every five minutes, so a newly labelled issue can take one poll cycle to
appear in Syrus. Use the repository's GitHub Issues panel in Syrus to
delegate an issue when you want Syrus to add the trigger label with the same
credential path it will later use for polling.

## Quick Examples

An ordinary Job:

```markdown
Please add CSV export to the reports page.
```

Labels:

```text
syrus
```

An Epic declaration:

```markdown
<!-- syrus-epic: Release hardening -->

Group the release hardening Jobs here.
```

A child Job attached to that Epic:

```markdown
<!-- syrus-epic: #123 -->

Tighten the checkout error message.
```

A child Job that must wait for another child Job:

```markdown
<!-- syrus-epic: #123 -->
depends on: #124

Update the docs after the API change lands.
```

Cross-repository references include `owner/repo` before the issue number:

```markdown
<!-- syrus-epic: acme/platform#123 -->
blocked by: acme/platform#124, acme/docs#8
```

Only the `syrus-epic` HTML comment is interpreted as Epic routing metadata.
Visible prose such as `Epic: #123`, quoted text, headings, or issue-template
fields are treated as ordinary issue text. To migrate an older template that
already contains an `Epic: ...` line, wrap that line in a Syrus marker block:

```markdown
<!-- syrus-epic
Epic: #123
-->
```

## Labels

`syrus` or the repository's configured trigger label tells Syrus to ingest
the issue. Syrus ignores issues without that label.

`syrus-skip` opts an issue out even if it also has the trigger label. Use it
when an issue should stay visible in GitHub but should not become a Syrus
Job.

`syrus-skip-prepare` creates or updates the Job with prepare disabled. Use it
only when the repository's normal `.syrus.yml` prepare step is unnecessary or
known to be harmful for that issue.

`syrus-track-<name>` selects a delivery track at ingest time. For example,
`syrus-track-hotfix` records `hotfix` as the Job's delivery track. If the
repository has no matching track configured, Syrus falls back to the default
delivery policy when resolving branches and graders.

`syrus-investigation` files the issue as an investigation instead of an
implementation. The agent explores the repository and writes up what it found;
it is not expected to change any code, and no pull request is opened. A blank
diff is a perfectly successful outcome. Use it for "go look into this and tell
me what you find" work — an audit, a QA walkthrough, or a question about how
something behaves.

The Job finishes in **Implemented** with a report to read, and you close it
from the Job page once you have. Add the label when you file the issue: it is
read at ingest, so adding it to an issue Syrus has already picked up does not
convert the existing Job.

When an investigation finds concrete follow-up work, it can propose a new Job.
That follow-up lands in triage first: an operator must accept it before Syrus
starts implementation, or reject it to close it as cancelled.

## Epic Markers

Syrus reads Epic markers only from explicit Syrus-owned HTML comments in the
issue body:

```markdown
<!-- syrus-epic: Release hardening -->
```

When the value is plain text, the issue declares an Epic. Syrus creates or
finds the Epic by the GitHub issue URL and uses the marker value as the Epic
title.

```markdown
<!-- syrus-epic: #123 -->
```

When the value is an issue reference, the issue becomes a child Job of the
Epic declared by that referenced issue. The reference can be same-repository
(`#123` or `123`) or cross-repository (`owner/repo#123`).

Visible prose such as `Epic: #123`, markdown headings, quoted text, and issue
template fields are ignored for Epic routing. Existing templates can migrate by
wrapping the old visible line in a marker block:

```markdown
<!-- syrus-epic
Epic: #123
-->
```

Values containing a broken `#` reference, such as `owner/repo#abc`, are
ignored. Marker values without `#` are treated as Epic declaration names unless
they are same-repository numeric references such as `123`. If Syrus ignores a
malformed Epic marker, the issue follows the ordinary Job ingestion path.

Filing order does not matter. If a child issue references an Epic before the
Epic issue itself has been ingested, Syrus creates the child Job in a pending
Epic-reference state. When the Epic issue is later labelled and ingested, Syrus
resolves the pending child automatically.

## Dependencies

Syrus reads dependency markers from issue-body lines that start with one of
these forms:

```markdown
depends on: #12
depends-on: #12
blocked by: #12
blocked-by: #12
```

You can list multiple references on one line:

```markdown
depends on: #12, #13, acme/infra#8
```

Same-repository references use `#<number>`. Cross-repository references use
`owner/repo#<number>`. The `#` is required here too: `depends on: 12` does
not create a dependency. Syrus parses at most 50 dependency references from
one issue body so a large issue cannot trigger unbounded lookup work.

On an ordinary Job or Epic child Job, these markers create Job dependencies.
On an Epic declaration issue, these markers create Epic-to-Epic
dependencies. That lets one Epic wait for another Epic declared by a GitHub
issue.

Dependency filing order does not matter. If a Job references an issue Syrus
has not ingested yet, Syrus stores a pending dependency. When the referenced
issue later becomes a Job, the pending dependency resolves automatically. If
an Epic declaration references an Epic issue Syrus has not ingested yet,
Syrus records a pending Epic dependency and resolves it when the referenced
Epic appears.

Parsed dependencies use the default satisfaction mode, `success`: the
dependent Job can land after the dependency succeeds. Within the same Epic,
Syrus can also start a downstream Job for execution once the upstream Job has
an implemented PR with branch and head SHA, so agents can build on earlier
Epic work before the whole Epic lands. Operators can manually add
dependencies with `closed` satisfaction for cleanup work that should wait
for a Job or Epic to finish whether it succeeds or is closed.

## Epic Ordering

Within a single Epic, Job-to-Job dependencies must form one linear chain.
Syrus rejects parsed or manually added dependencies that would fork one Epic
child into multiple downstream children, or merge multiple upstream Epic
children into the same child. This keeps Epic branches and merge trains
ordered in the same sequence Syrus will later integrate.

A common pattern is:

```markdown
# Issue 124
<!-- syrus-epic: #123 -->

Build the database model.

# Issue 125
<!-- syrus-epic: #123 -->
depends on: #124

Add the API endpoint.

# Issue 126
<!-- syrus-epic: #123 -->
depends on: #125

Document the endpoint.
```

Cross-Epic dependencies are allowed. When a Job in one Epic depends on a Job
in another Epic, Syrus also derives an Epic-to-Epic ordering relationship so
the landing queue and merge trains see the larger dependency.

## What Syrus Ignores

Syrus does not ingest:

- Closed issues.
- Pull requests listed as issues by the GitHub API.
- Issues without the repository trigger label.
- Issues with `syrus-skip`.
- Malformed explicit Epic marker references such as
  `<!-- syrus-epic: owner/repo#abc -->`.
- Dependency references without `#`, such as `depends on: 123`.

If a labelled issue already has a linked open pull request from someone
else, Syrus treats it as externally implemented instead of opening a
competing PR.

For debugging, see [The poller never picks up my issue](/docs/troubleshooting#the-poller-never-picks-up-my-issue).
