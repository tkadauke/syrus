# Connected Accounts

Connected Accounts is an experimental, default-disabled plugin that stores safe external-account metadata and brokers short-lived OAuth access through Credential Store. It does not provide a service integration by itself.

Tools must use `ConnectedAccounts::AccountClient.with_access`. The client requires an existing permission-authorized invocation, verifies account ownership, status, acting mode, granted scopes, and the account ceiling, and invalidates materialized access when the block ends. Stored access and refresh tokens are never placed in an environment, command line, workspace file, or transcript.

OAuth credentials use the `connected_accounts.oauth` type. Their `allowed_tools` must contain only `connected_accounts.account_client`, and `allowed_url_prefixes` must pin the provider API origins.
