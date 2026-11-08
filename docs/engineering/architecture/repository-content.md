# Repository content

`RepositoryContent` reads repository data without cloning it. Call
`RepositoryContent.for(repository).resolve(ref)` once to obtain an immutable
revision, then use `tree`, `read`, or `changes` against that revision. Results
are cached by repository and revision.

Providers register through `:repository_content_provider` and are tried in
priority order, with replicas before upstreams. The bundled local Git mirror
provider can answer first; the GitHub host provider is the upstream fallback.
Provider results have deliberate semantics:

- `NotFound` is a final answer: do not ask another provider.
- `Unavailable`, `Unsupported`, and `UnknownRevision` may fall through.
- `Truncated` carries a partial answer and is only acceptable to display code
  that explicitly supports partial results.

This distinction prevents an outage from masquerading as an absent file.
Pre-workflow `.syrus.yml` reads, preview projects, repository skills, Job source
browsing, diff viewing, and PR reads all use this abstraction. Core code must
not read content through `GithubClient` directly.

The boundary starts at `app/services/repository_content.rb`; providers live in
their owning plugins. Architecture enforcement is in
`spec/architecture/repository_content_reads_spec.rb`. Core tests use the fake
provider in `spec/support/repository_content.rb` and `stub_repository_content`
instead of network requests.
