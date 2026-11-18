# Connected accounts

Connected Accounts is an experimental, default-disabled plugin that stores safe metadata for user-owned external accounts and keeps OAuth token payloads encrypted in Credential Store.

Tool plugins request block-scoped access through `ConnectedAccounts::AccountClient`. Access is refused unless the account is connected, belongs to the invoking user, permits the requested acting mode and scopes, and the permission system supplied an authorized invocation reference. Tokens are held in memory only and are redacted from results and errors.

Before access is yielded, the client validates the stored token expiry. Expired tokens are replaced atomically through Credential Store when the account provider has configured a refresh handler; otherwise access fails closed. Invalid, missing, or still-expired replacement tokens are rejected without replacing the stored credential.

The plugin refreshes expiring accounts in the background and periodically asks each provider to validate account health. A failed refresh moves the account to `needs_reauth` and creates an approval-inbox notification. Disconnecting calls the provider's revocation endpoint when available, erases stored token material, and retains the non-secret account and credential-access audit history.

## Configuring a generic OAuth 2 provider

Administrators can add standards-based providers at **Admin → OAuth providers** without installing Ruby code. Supply HTTPS authorize and token endpoints, optional revocation and identity endpoints, the supported scopes, and the allowed API origins. The OAuth client id and secret fields are write-only: Syrus stores them as an instance-scoped `connected_accounts.oauth_client` credential in Credential Store rather than in plugin settings or provider metadata.

The callback URL to register with the provider is `/api/v1/app/connected_accounts/callback/<provider-key>` on the public Syrus base URL. Authorization uses a short-lived, single-use server-side state record and PKCE. Callback failures return only a fixed error code to the settings page; callback codes, state values, client secrets, and provider response bodies are never included in redirects or error pages.

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
      { key: "records.read", label: "Read records", risk: "low", syrus_capabilities: [ "records.read@v1" ] }
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

Token-bearing `exchange_code` and `refresh` results are returned only to the Connected Accounts broker. Providers must not log token material or include it in exceptions, user-visible output, or other external results. The manifest scope catalog constrains `requested_scopes`: each entry has a provider scope `key`, a human `label`, its `risk`, and the `syrus_capabilities` that scope enables. `callback_route` must be an absolute path owned by the contributing plugin, and `supports_read_only` states whether the authorization flow can limit the resulting connection to read-only access.

Provider gems can require `connected_accounts/provider_test_kit` and run the shared `"a connected accounts provider"` examples with their declaration and provider. The fake provider bundled with Connected Accounts is the executable reference implementation.
