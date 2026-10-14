# Scrub Bare Clone Remote Credentials

Type: one-off cleanup.

Syrus stores local bare clones under the data root so background jobs can read repository history without keeping a workflow workspace alive. Older bare clones may have saved the authenticated clone URL in `remote.origin.url`, including a GitHub App installation token or user PAT.

This task scans existing bare clone configs and removes those credential-bearing remotes. When the clone maps to a current Repository record, the task rewrites `origin` to the repository's anonymous `remote_url`. If the clone directory no longer maps to a repository, the task removes the credentialed `origin` remote instead.

New bare clones scrub their remote immediately after clone, so this task is only for historical on-disk configs.

Expected load: local filesystem and git config updates only. It does not call GitHub, fetch repositories, or mutate repository records.
