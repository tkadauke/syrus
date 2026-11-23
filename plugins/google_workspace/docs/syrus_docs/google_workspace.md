# Google Workspace

The experimental `google_workspace` plugin provides read-only Gmail and Google Calendar access through the generic Mail and Personal Calendar tools. It is disabled by default and depends on `connected_accounts`, `mail`, and `personal_calendar`.

## Register an OAuth client

In Google Cloud, create an OAuth 2.0 web application client and add the callback URL shown by Syrus for the `google_workspace` provider. Enter that client's id and secret in the Connected Accounts provider configuration. The secret is encrypted and is never returned after it is saved. Every Syrus instance supplies its own client. Before enabling connections, check Google's current OAuth consent-screen, app-verification, and testing-status policies; these policies can change.

The provider requests offline access with PKCE so it can refresh access without exposing tokens. Gmail and Calendar are separate read-only scopes selected at connect time; connecting Calendar alone does not grant Gmail access. Reauthorizing an account can add the Gmail scope without disconnecting it. Gmail's read scope is restricted, so operators must check Google's current verification and restricted-scope policies rather than rely on policy details embedded in Syrus. The plugin never sends mail or creates, edits, shares, invites, or deletes events.

## Connect and disconnect

Enable the plugin, save the Google provider configuration, then open **Settings → Connected accounts** and connect Google. Google displays the exact requested permissions before consent. Gmail reads use the provider-neutral `mail_search` and `mail_read_message` tools; Calendar reads use `personal_calendar_list_events` and `personal_calendar_get_event`. Gmail message bodies are returned as bounded plain text. Attachments are listed by filename, media type, and size but are not downloaded.

Disconnect the account from **Settings → Connected accounts**. Syrus asks Google to revoke the grant when possible, removes the stored credential, and retains only the normal audit history. If Google revokes or expires a grant first, Syrus marks the account as needing reauthorization instead of retrying it indefinitely.
