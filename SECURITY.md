# Security Policy

## Reporting a vulnerability

Please disclose suspected vulnerabilities privately through GitHub private
security advisories for this repository. Do not open a public issue or PR for a
vulnerability until maintainers have had time to investigate and coordinate a
fix.

Include as much detail as you can safely provide:

- A description of the vulnerability and its impact.
- Steps to reproduce it.
- Affected versions, commits, or deployment configuration.
- Any logs or traces needed to understand the issue, with secrets redacted.

Never include live GitHub tokens, LLM API keys, Rails credentials, session
cookies, or private repository contents unless maintainers explicitly request a
secure transfer path.

## Supported scope

Syrus is intended for self-hosted deployments operated on infrastructure the
operator controls. It requires access to sensitive credentials, including
GitHub tokens and LLM provider API keys or credentials, and it runs repository
setup commands and agent-authored code in worker-managed workspaces.

The worker workspace model protects the operator checkout from accidental path
mistakes, but it is not a hardened sandbox for untrusted code. Operators should:

- Run Syrus only on infrastructure they control.
- Connect repositories whose code and setup commands they are willing to
  execute.
- Scope GitHub tokens and app installations as narrowly as practical.
- Keep secrets out of repositories and issue bodies.
- Review generated PRs before merging.
- Keep deployments current with security fixes.

Security support focuses on the current main branch and actively maintained
self-hosted deployments. Older commits, local modifications, third-party
deployment wrappers, and infrastructure outside the Syrus application may be
out of scope unless the issue also affects supported Syrus code.

## Response expectations

Maintainers aim to acknowledge private vulnerability reports within 7 days.
After acknowledgement, the expected next steps are:

- Triage the report and confirm whether it affects supported Syrus code.
- Share an estimated remediation plan or ask for more information.
- Prepare and review a fix privately when disclosure risk requires it.
- Publish the fix and coordinate public disclosure once users can update.

Complex issues may take longer to fix, especially when they involve deployment
configuration or credential handling. Maintainers will provide status updates
as the investigation progresses.
