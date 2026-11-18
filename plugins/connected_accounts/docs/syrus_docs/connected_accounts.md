# Connected accounts

Connected Accounts is an experimental, default-disabled plugin that stores safe metadata for user-owned external accounts and keeps OAuth token payloads encrypted in Credential Store.

Tool plugins request block-scoped access through `ConnectedAccounts::AccountClient`. Access is refused unless the account is connected, belongs to the invoking user, permits the requested acting mode and scopes, and the permission system supplied an authorized invocation reference. Tokens are held in memory only and are redacted from results and errors.

Before access is yielded, the client validates the stored token expiry. Expired tokens are replaced atomically through Credential Store when the account provider has configured a refresh handler; otherwise access fails closed. Invalid, missing, or still-expired replacement tokens are rejected without replacing the stored credential.

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

Provider gems can require `connected_accounts/provider_test_kit` and run the shared `"a connected accounts provider"` examples with their declaration and provider. The fake provider bundled with Connected Accounts is the executable reference implementation.
