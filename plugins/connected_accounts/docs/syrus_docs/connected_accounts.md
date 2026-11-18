# Connected Accounts

Connected Accounts is an experimental, default-disabled plugin that stores safe external-account metadata and brokers short-lived OAuth access through Credential Store. It does not provide a service integration by itself.

Tools must use `ConnectedAccounts::AccountClient.with_access`. The client requires an existing permission-authorized invocation, verifies account ownership, status, acting mode, granted scopes, and the account ceiling, refreshes expired access through the account provider, and invalidates materialized access when the block ends. Stored access and refresh tokens are never placed in an environment, command line, workspace file, or transcript.

OAuth credentials use the `connected_accounts.oauth` type. Their `allowed_tools` must contain only `connected_accounts.account_client`, and `allowed_url_prefixes` must pin the provider API origins.

Account integrations contribute to `connected_accounts:provider`. A refresh-capable provider exposes a stable `key` matching the account's provider key and implements `refresh(account:, payload:)`, returning the complete replacement OAuth JSON payload. Access fails closed when no unique refresh-capable provider matches an expired account.
