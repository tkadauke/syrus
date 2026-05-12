# Bot-authored commits and signed-commit protection

When a repository is connected through the GitHub App installation, Syrus configures each workflow workspace to author commits as the App bot:

```text
<github_app_slug>[bot] <<github_app_slug>[bot]@users.noreply.github.com>
```

Those commits are created with local `git commit` in the workflow workspace, so GitHub treats them as unsigned. They can show as unverified, and branches protected with "Require signed commits" may reject pushes from Syrus.

Until Syrus moves App-authored writes to GitHub's GraphQL `createCommitOnBranch` API, operators using required signed commits should exempt `syrus/*` branches from that rule or disable the rule for repositories delegated to Syrus.
