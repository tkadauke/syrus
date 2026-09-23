# GitHub Host

GitHub Host reads repository content from GitHub without a checkout: files,
trees, what changed between two commits, commit history, and commit tree
SHAs. It is the `:upstream`
`repository_content_provider` for every git repository Syrus knows, answering
through the GitHub API with the repository's App installation token or its
owner's PAT.

It is separate from GitHub Source on purpose. GitHub Source ingests issues and
operates pull requests; GitHub Host only reads code. A future GitLab or
self-hosted plugin would provide the same extension point for its repositories.

## What uses it

Anything in Syrus that reads a repository before or without a workspace
clone: the pre-clone `.syrus.yml` read that decides which workflow steps to
build, preview project discovery, skills, deploy stages, feature
recommendations, and the Job source browser. It also answers `divergence`
(numeric ahead/behind commit counts, from GitHub's compare API) for
`CommitsBehindCalculator`, the merge-state poller's `commits_behind_base`
calculation, whenever no faster replica (`git_mirror`) can.

## How it answers

- A 40-character commit SHA is taken as already resolved; branches and tags
  cost one API call, and `RepositoryContent` reuses the answer for 60 seconds.
- Reads are keyed by commit, so repeat reads of the same file at the same
  commit are served from the Syrus cache, not GitHub.
- Files over the contents API's 1 MB inline limit are fetched through the git
  blob API.
- GitHub truncates very large trees (around 100,000 entries) and lists at most
  300 files or 250 commits per comparison. Rather than return a partial answer
  as if it were complete, GitHub Host raises `RepositoryContent::Truncated`
  carrying what it got: a mirror plugin can answer instead, and display code
  (the source browser, the diff viewer) shows the partial list flagged as
  truncated.

Errors map onto the content contract: a missing file is `NotFound`, an unknown
ref or commit is `UnknownRevision`, and rate limits, 5xx responses,
authentication failures, and timeouts are `Unavailable`.

## Upstream source for mirrors

GitHub Host also answers `upstream_source`: the repository's HTTPS clone URL
and a credential to fetch it -- the App installation token (with its expiry)
or else the owner's PAT, as the password for the `x-access-token` user. A
mirror plugin uses this to keep its copy in sync.

## Disabling

Disabling is blocked while any active repository would be left with no other
content provider -- today, that is every repository, until a mirror plugin
serves them. See `plugins.md` (`repository_content_provider`) for the contract.
