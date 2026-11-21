# Review capability family

The Review family includes the provisional `external_reviewer` capability for
external review and explainer services. A Review facet returns a service that
implements the public `Syrus::Host::ExternalReviewer` contract. Providers have
a stable `provider_key`, human-readable `display_name`, declared capabilities,
and an `available_for?` predicate over the host-supplied immutable context.

Declared capabilities are `artifact`, `asynchronous_completion`, `polling`,
`webhook_delivery`, `feedback`, `verdict`, `cancellation`, and
`provider_managed_github_publication`. Services submit work, refresh an existing
submission, and may cancel it. They normalize every response to an accepted,
completed, declined, retryable-failure, or terminal-failure result. Results may
carry an external identifier, idempotency key, retry hint, typed artifact
descriptors, feedback, a verdict, publication disposition, and opaque metadata.

Core owns persistence, retries, trigger and rule evaluation, exact-SHA staleness,
authorization, audit, GitHub publication, landing policy, and artifact storage.
Providers own provider-specific dispatch and response normalization. A provider
that publishes to GitHub declares that capability and reports the disposition;
doing so does not transfer authorization, audit, or landing-policy ownership.

Future repository review policy belongs in `.syrus.yml`. Provider enablement,
connections, credentials, and runtime state are instance data. The context
therefore supplies public repository, Job, pull-request, connected-account, and
client facades rather than Active Record objects, OAuth tokens, `GithubClient`,
or other host internals. It also carries exact base/head SHAs, the diff review
version, trigger/rule data, links, summary, and evidence. For refresh and
cancellation, core copies the normalized external identifier and idempotency key
back into a new context; providers do not retain lifecycle state in core.

This contract does not define persistence, configuration parsing, jobs,
webhooks, UI, media/video transport, landing gates, or a concrete provider.
