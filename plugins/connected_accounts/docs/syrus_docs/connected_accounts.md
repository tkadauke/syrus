# Connected accounts

Connected Accounts is an experimental, default-disabled plugin that stores safe metadata for user-owned external accounts and keeps OAuth token payloads encrypted in Credential Store.

Tool plugins request block-scoped access through `ConnectedAccounts::AccountClient`. Access is refused unless the account is connected, belongs to the invoking user, permits the requested acting mode and scopes, and the permission system supplied an authorized invocation reference. Tokens are held in memory only and are redacted from results and errors.
