# Coworkers

Coworkers is an experimental, instance-local capability for persistent named
agents. It is disabled by default and requires beta mode before an administrator
can enable it.

The initial foundation stores user-owned coworker identities, globally unique
handles, model preferences, workspace remotes, appearance, explicit capability
grants, and main or side chat links. Existing chats remain Syrus chats unless a
coworker chat link explicitly assigns them to a coworker.

Coworker creation validates and tests the GitHub remote before creating any
records. It registers a previously unknown remote with polling and PR
automations disabled, then seeds an isolated `coworkers/<handle>` home branch.
Existing repository registrations are reused without changing their settings.
The coworker's owner receives write membership when a shared registration is
reused, so workspace Jobs remain authorized for every coworker owner.
The remote's default branch is never modified.

Coworker chats use a separate, deny-by-default MCP surface. Administrator
ownership does not add administrator or repair tools. Every core tool on the
surface names the coworker grant required to advertise it, and interactive
question/suggestion tools are present only while handling an owner-authored
turn. Plugin chat tools are excluded unless their tool set and definitions
explicitly opt into coworker use. The Agent Memory plugin opts in only its
read, search, and list tools. Shared-chat reads are restricted to the
coworker's own chats and chats explicitly shared with that coworker, even
when its owner is an administrator.

Grant approval policies are enforced at invocation: `auto` executes directly,
while `confirm` and `queue` create the standard pending-action card for owner
approval. Revoking either workspace grant also changes the provider-native
tool boundary. Claude can deny file and shell tools independently; providers
without that separation fail closed rather than starting with permissions
they cannot enforce.

In the Phase 1 workspace model, a turn runs directly in a checkout of the
coworker's `coworkers/<handle>` home branch. `SOUL.md`, `AGENTS.md`, and
`USER.md` are loaded into every fresh or resumed turn under bounded per-file
and aggregate byte limits. The agent process receives neither the ordinary
chat CLI invocation token nor a Git askpass token, so the owner's repository
credentials and integration credentials are not exposed to its shell.

When enabled, the plugin adds a Coworkers page and unread badge. Syrus is
pinned first as the built-in engineer; custom coworkers show their configured
color and avatar. The creation form collects the workspace remote, appearance,
model, grants, and optional About text. Uploaded avatars are size-limited and
resized before Active Storage saves them. Coworker chats are grouped separately
in the chat sidebar, and assistant messages use the coworker's avatar and color.
Coworker chats carry a named badge in global search, chat search, and the
agent-facing chat search tool. The shared chat filter offers each of the
current user's coworkers plus Syrus, where Syrus means a chat without a
coworker link.

Chat owners can share a chat read-only with one of their own coworkers from
the normal share dialog. A coworker with the `chats.read_shared` grant can
list, search, and read its own chats plus those shares; revoking a share
removes access immediately. Coworkers are never offered the arbitrary
`send_chat_message` tool.

Coworkers with the `coworker.message` grant can use
`message_coworker(handle, text)` to contact another active coworker owned by
the same user. Delivery is queued on the chat queue. The sender's main chat
records an outgoing block, while the receiver's main chat gets a
"message from @handle" block that waits behind any turn already in flight.
Paused and archived coworkers, Syrus, the sender itself, and handles outside
the owner's coworker list are refused. Deliveries carry their origin turn and
hop count; a chain cannot continue beyond three hops. Each pair of coworkers
can queue at most ten messages in a ten-minute window, regardless of direction.

Chat owners can also add their coworkers to a chat's agent roster from the
coworker page or by choosing an autocomplete result marked "Add to chat."
Rostered coworkers become addressable by every participant in that chat and
an exact structured mention starts a coworker turn using the chat owner's
settings. A coworker is also implicitly addressable in its own main and side
chats without a roster entry. Coworkers that are neither the chat's implicit
coworker nor on its roster remain plain text and do not start a turn. Rostered
coworkers can be removed by the chat owner, and coworkers owned by anyone else
cannot be added. The roster is shown beside the chat heading. Coworker turns
share the chat's serialization lane, so two turns in one chat do not run at the
same time.

Profile pages render `SOUL.md` read-only. The Activity tab reports sent and
received coworker-message traffic for the last 30 days. Capabilities, Schedule,
Memory, and Workspace are visible as coming-later placeholders where their
full Phase 1 surface has not shipped yet.
