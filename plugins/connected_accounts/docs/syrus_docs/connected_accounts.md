# Connected accounts

Connected Accounts is an experimental, default-disabled plugin that stores safe metadata for user-owned external accounts and keeps OAuth token payloads encrypted in Credential Store.

Tool plugins request block-scoped access through `ConnectedAccounts::AccountClient`. Access is refused unless the account is connected, belongs to the invoking user, permits the requested acting mode and scopes, and the permission system supplied an authorized invocation reference. Tokens are held in memory only and are redacted from results and errors.

Before access is yielded, the client validates the stored token expiry. Expired tokens are replaced atomically through Credential Store when the account provider has configured a refresh handler; otherwise access fails closed. Invalid, missing, or still-expired replacement tokens are rejected without replacing the stored credential.

Connections use authorization code with PKCE. The opaque state is bound to the signed-in user and browser session, expires after ten minutes, and can be consumed only once. The callback stores access and refresh material together as one encrypted Credential Store value. Providers may return fewer scopes than requested; the recorded grant and ceiling are reduced to the scopes actually returned.

The bundled generic OAuth 2 provider is configured per instance with HTTPS authorization, token, identity, optional validation and revocation endpoints, a client ID and encrypted secret, a scope catalog, the subset of those scopes that is safe for read-only connections, and permitted API origins. Its configured scope catalog is the source of the scopes offered by its connect flow; read-only scope membership is explicit and never inferred from a scope's spelling. Its API origins become URL-prefix constraints on every stored credential.

A maintenance job refreshes credentials shortly before expiry under Credential Store's row lock and probes provider health. Temporary provider failures use bounded job backoff. Invalid refresh authorization and unhealthy validation move the account to `needs_reauth`. Disconnect attempts provider revocation, then always revokes the local credential and marks the account revoked; provider failures are recorded without token material.

## Adding an account provider

A service plugin contributes to the hosted `connected_accounts:provider` extension point. The manifest declaration is the source of truth for the provider key and display name, callback path, read-only support, capabilities, and scope catalog. Every scope supplies a human label, a risk (`low`, `medium`, `high`, or `critical`), and the Syrus capabilities it enables.

```ruby
provides "connected_accounts:provider" => [
  {
    provider: "ExampleService::AccountProvider",
    key: "example",
    display_name: "Example Service",
    capabilities: %w[authorization exchange_code refresh revoke identity validate events],
    callback_route: "/connected_accounts/callback/example",
    supports_read_only: true,
    scopes: [
      { key: "records.read", label: "Read records", risk: "low", read_only: true, syrus_capabilities: [ "records.read@v1" ] }
    ]
  }
]
```

The provider implements one class method per declared capability. Each method accepts exactly one context object from `ConnectedAccounts::Provider`; positional argument lists are not part of the contract. `authorization`, `exchange_code`, `refresh`, `revoke`, `identity`, and `validate` are required. `events` is provisional and optional, but must be implemented when declared. Invalid declarations and missing methods are withheld and degrade the contributing plugin in plugin health.

The capability contexts and results are:

| Capability | Context fields | Result |
| --- | --- | --- |
| `authorization` | `redirect_uri`, opaque `state`, `requested_scopes`, and `read_only` | A hash containing `authorize_url`. A non-OAuth provider may return the URL or instruction flow it uses for its trivial authorization step. |
| `exchange_code` | Provider callback `code` and the original `redirect_uri` | A token hash containing `access_token`; include `refresh_token` and `expires_in` when the service supplies them. |
| `refresh` | The current `tokens` hash | A replacement token hash containing `access_token` and preserving or replacing the other usable token fields. |
| `revoke` | The current `tokens` hash | A hash containing boolean `revoked`. |
| `identity` | `access_token` | A hash containing the human-readable external identity `label`. |
| `validate` | `access_token` | A health result containing boolean `healthy` and a safe, non-secret `message`. |
| `events` | Request `headers` and raw request `body` | After verifying authenticity, a normalized hash containing `event_id`, `event_type`, and `data`. Invalid signatures must fail closed. |

Token-bearing `exchange_code` and `refresh` results are returned only to the Connected Accounts broker. Providers must not log token material or include it in exceptions, user-visible output, or other external results. The manifest scope catalog constrains `requested_scopes`: each entry has a provider scope `key`, a human `label`, its `risk`, an explicit boolean `read_only`, and the `syrus_capabilities` that scope enables. `callback_route` must be an absolute path owned by the contributing plugin, and `supports_read_only` states whether the authorization flow can limit the resulting connection to scopes marked `read_only`. The generic provider takes the equivalent read-only subset from its instance configuration.

Provider gems can require `connected_accounts/provider_test_kit` and run the shared `"a connected accounts provider"` examples with their declaration and provider. The fake provider bundled with Connected Accounts is the executable reference implementation.
