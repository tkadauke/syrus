---
title: About Syrus
description: The naming story, project history, and maintainer behind Syrus.
---

# About

Syrus is a project about turning small pieces of written intent into
durable changes in code. For the technical version of what it is, start
with [the concepts guide](/docs/concepts). This page is the other version:
where the name came from, how the project started, and who to ask when
something looks interesting or broken.

## The Name

Syrus is named after [Publilius Syrus](https://en.wikipedia.org/wiki/Publilius_Syrus),
the 1st-century-BCE Roman writer whose *Sententiae* were copied, taught,
and reused as schoolbook material for more than a millennium. He wrote
compact maxims: small pieces of text built to travel farther than their
first occasion. Phrases he coined, or that are commonly credited to him,
still turn up in ordinary English: "honor among thieves," "the end
justifies the means,"
"necessity knows no law," "a rolling stone gathers no moss," and
"a good reputation is more valuable than money." However tangled the chain
of translation, attribution, and reuse, that is real literary gravity, not
a footnote. He is one of those rare ancient writers whose lines escaped
the page and became common furniture for everyday thought. Put plainly:
legal, moral, and common-sense English still quote him, often through
people who no longer know the source. It is one thing to write a clever
line. It is another for ordinary language, schoolbooks, and arguments to
still carry pieces of that line two thousand years later.

That is the part the project borrows. Syrus exists to take a short issue,
review comment, or scheduled prompt and turn it into a pull request that
keeps its value after the agent turn is over. Publilius Syrus was enslaved
before he became known as a writer; the traditional account says his wit
and genius caught the attention of his master, who educated him and freed
him because of it. That history belongs in the account, but it is
context rather than the pitch. The pitch is the writerly one from the README:
small, durable text that compounds.

## How It Started

Syrus was sketched on a plane on May 1, 2026, then created as a repository
that same evening. The first goal was narrow: replace a pile of per-repo
automation scripts with one Rails app that owned the boring mechanics of
clones, branches, pull requests, cleanup, and retries.

By day two, Syrus was already working on itself. That early recursion has
stayed central to the project: if Syrus is supposed to make issue-to-PR
work dependable, it should be able to carry its own maintenance work too.
The public website was planned as Syrus jobs. The auto-rebase feature was
itself shipped through Syrus running auto-rebase. The tool keeps eating the
same work it promises to make easier.

## Who Maintains It

Syrus is maintained by [Thomas Kadauke](https://github.com/tkadauke).
GitHub is the best contact path for now: open an issue, start a discussion,
or mention `@tkadauke` on a pull request if the context belongs in the
project.

If you are evaluating Syrus for a team and need a private contact route,
Thomas can add the preferred email or social link here before launch.

---

[Back to home](/) | [GitHub](https://github.com/tkadauke/syrus) | [Try Syrus locally](/docs/deployment/try-it-locally)
