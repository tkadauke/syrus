# Local Mode

Local Mode lets a chat agent read and write files, run commands, and inspect
git state in an operator's own checkout over an authenticated reverse tunnel.
No server-side clone is required. The `local_mode` feature is off by default
because it opens an execution bridge to the operator's machine.

## Pairing

Choose Local Mode in a chat and copy the generated `syrus local --chat ...
--token ...` command into the repository checkout. Only the chat owner may
create, replace, or terminate its pairing; other group-chat participants can
see connection status. The account token is sent in authorization headers,
not URLs. A successful connection reports the repository and branch to the
chat. Missed heartbeats disconnect the session after 45 seconds and require a
fresh pairing.

## Tools and authorization

The daemon supports `read_file`, `write_file`, `list_files`, `run_command`,
`git_diff`, `git_diff_staged`, and `git_status` within the paired repository
root. Escaping that root is rejected.

Reads run immediately. Writes and commands require confirmation. Confirming an
ordinary call grants a revocable, chat-and-checkout-specific permission for
the exact normalized invocation, so an identical safe call need not be
confirmed repeatedly. Network, credential, secret, destructive, and elevated
calls always require a new confirmation. A deny rule blocks the call without
asking.

## Limitations

- One daemon session per chat.
- The pairing token is sensitive and authorizes access for that chat.
- A connection lost past the heartbeat timeout must be paired again.
