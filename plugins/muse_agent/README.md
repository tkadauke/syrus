# Muse Agent

Muse Agent is the initial Syrus plugin shell for Muse Code.

This plugin currently owns only the credential surface:

- `User#muse_api_key` encrypted storage
- `/credentials` save, clear, and test support
- a `CredentialProbe` registration while the plugin is enabled
- secret extraction so probe output and logs redact the saved key

It intentionally does not register `AgentProviders::Muse` or
`ChatProviders::Muse` yet. Workflow execution stays unavailable until Muse
invocation, transcript normalization, and required MCP tool support are wired
and tested.

The credential probe verifies that `muse` is available and runs:

```sh
muse exec --api-key-stdin "Reply with OK."
```

The API key is passed on stdin, never in argv.
