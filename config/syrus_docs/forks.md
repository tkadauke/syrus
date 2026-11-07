# Forks and upstreams

A repository can be registered as a **fork** of an **upstream** repository that
also lives in this Syrus instance. Configure the upstream owner, repository,
and default branch on the repository form.

When adding a GitHub fork, Syrus pre-fills those fields from GitHub metadata.
They remain editable and can be cleared before submission. Detection failures
do not prevent onboarding, and existing repositories are not changed
retroactively.

## Jobs on a fork branch off the upstream's default branch

For a fork whose upstream is registered in the instance, Jobs base their work
on the upstream default branch, measure the three-dot diff against it, and open
the pull request directly against that upstream. Non-forks, unregistered
upstreams, and stacked child Jobs retain their normal base behavior. Fetching a
private upstream is not supported.

## Keeping the fork's own default branch current

Fork auto-sync is off by default. When enabled, Syrus asks GitHub to sync the
fork default branch from its upstream every 15 minutes. Repository settings
also provide **Sync now** for registered upstreams regardless of the toggle.
Conflicts and repositories GitHub cannot sync are reported without crashing
the scheduler.

Auto-sync affects only the fork default branch. Jobs remain correct without it
because eligible Jobs already branch directly from the upstream.
