# Connected accounts

Connected Accounts is an experimental, default-disabled plugin that stores safe metadata for user-owned external accounts and keeps OAuth token payloads encrypted in Credential Store.

Tool plugins request block-scoped access through `ConnectedAccounts::AccountClient`. Access is refused unless the account is connected, belongs to the invoking user, permits the requested acting mode and scopes, and the permission system supplied an authorized invocation reference. Tokens are held in memory only and are redacted from results and errors.

Before access is yielded, the client validates the stored token expiry. Expired tokens are replaced atomically through Credential Store when the account provider has configured a refresh handler; otherwise access fails closed. Invalid, missing, or still-expired replacement tokens are rejected without replacing the stored credential.
