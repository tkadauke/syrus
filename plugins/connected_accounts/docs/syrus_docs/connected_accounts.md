# Connected Accounts

Connected Accounts is an experimental, default-disabled plugin that depends on
Credential Store. It owns user-connected external account metadata and provides
one brokered client for permission-authorized tools. OAuth access and refresh
tokens remain encrypted in Credential Store and are never exposed through a
process environment, command line, workspace file, or transcript.

Accounts record their provider, external identity label, granted scopes, scope
ceiling, eligible acting modes, and connection status. Tools must request an
explicit account, acting mode, and subset of its scopes through
`ConnectedAccounts::AccountClient`; direct credential-broker calls from other
plugin tool names are denied.
