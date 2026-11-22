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

## Minimal provider

An implementation has two deliberately small layers. The Review-family facet
lets core discover the service without loading provider code during catalog
inspection; the service implements the public host contract and returns only
normalized values:

```ruby
class ExampleReviewFacet
  def self.key = :example
  def self.display_name = "Example Review"
  def self.external_reviewer(_context) = ExampleReviewer
end

class ExampleReviewer
  extend Syrus::Host::ExternalReviewer

  def self.provider_key = :example
  def self.display_name = "Example Review"
  def self.capabilities = %i[asynchronous_completion polling verdict]
  def self.available_for?(context) = context.connected_account.provider_key == :example

  def self.submit(context)
    response = context.client.submit(head_sha: context.head_sha, idempotency_key: context.idempotency_key)
    Syrus::Host::ExternalReviewResult.accepted(
      external_id: response.id, idempotency_key: response.idempotency_key,
      retry_after: response.retry_after
    )
  end

  def self.refresh(context)
    response = context.client.read(context.external_id)
    return Syrus::Host::ExternalReviewResult.accepted(
      external_id: context.external_id, idempotency_key: context.idempotency_key,
      retry_after: response.retry_after
    ) unless response.finished?

    Syrus::Host::ExternalReviewResult.completed(verdict: response.verdict)
  end
end
```

Declare the facet as a provisional Review-family provider in the plugin
manifest. In the plugin spec, require `syrus/plugin/test_kit`, use the generated
`"a valid review provider"` example for the facet declaration, and use
`"a valid external reviewer"` with submit and refresh contexts for the service.
The latter calls every operation through the shared plugin invocation boundary,
so provider exceptions, timeouts, health findings, and circuit breaking have
the same semantics in the contract test and at runtime.

## Optional capability absence

Providers declare only behavior they implement. The normalized absence for
every optional capability is:

| Capability | Behavior when absent |
|---|---|
| `artifact` | Return an empty `artifacts` array. |
| `asynchronous_completion` | `submit` completes synchronously; it does not return `accepted`. |
| `polling` | `refresh` returns `declined`; webhook-only providers still implement the method. |
| `webhook_delivery` | No inbound delivery is promised by this contract. |
| `feedback` | Return `feedback: nil`. |
| `verdict` | Return `verdict: nil`. |
| `cancellation` | Inherit `cancel`, which returns `declined`; declaring the capability requires overriding it. |
| `provider_managed_github_publication` | Return the default `publication: :core`; the provider must not publish. |

Contexts must contain frozen public facade values. They never contain host
records, raw credentials, or `GithubClient`. A provider can describe artifacts,
feedback, verdicts, publication, and retry guidance only through immutable
`ExternalReviewResult` values; those values grant no method for changing a Job,
Workflow, GitHub state, artifact storage, or landing state.
