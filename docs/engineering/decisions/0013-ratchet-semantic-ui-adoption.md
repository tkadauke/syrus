---
id: ADR-0013
title: Ratchet semantic UI adoption
status: accepted
date: "2026-11-07"
supersedes: []
superseded_by: []
---

# ADR-0013: Ratchet semantic UI adoption

## Context

A big-bang conversion of established UI styling is risky and difficult to
review, while report-only guidance allows new raw colors and duplicated
primitives to increase the debt indefinitely. A fixed baseline separates known
legacy debt from regressions introduced by new work.

## Decision

Semantic UI adoption uses a ratchet: baseline existing debt, block new debt in
enforced categories, measure remaining report-only categories, and graduate a
category only when its migration is ready. Historical baseline counts are
implementation data, not a permanent architectural promise.

## Consequences

Ordinary changes cannot worsen enforced debt, and migration can proceed in
reviewable increments. Baselines need intentional updates when debt is removed
or a rule graduates; they must not become an escape hatch for new violations.

## Evidence

- [Frontend conventions](../conventions/frontend.md)
- [Design-system ESLint rules](../../../eslint-rules)
- [Frontend lint configuration](../../../eslint.config.js)
- [Style-debt report](../../../bin/style-debt-report)
