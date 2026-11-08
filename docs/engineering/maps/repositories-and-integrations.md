# Repository and integration map

| Concern | Primary locations |
| --- | --- |
| Repository model/settings | `app/models/repository.rb`, repository services under `app/services/` |
| No-clone content boundary | `app/services/repository_content.rb` |
| Content-provider contract | provider classes in owning plugins, `spec/support/repository_content.rb` |
| GitHub clients | `app/services/github_client.rb`, focused GitHub services under `app/services/` |
| Input-source polling | `app/jobs/poll_all_input_sources_job.rb`, `app/jobs/poll_input_source_job.rb` |
| PR feedback/merge polling | `app/jobs/poll_all_pull_requests_job.rb`, `app/jobs/poll_pull_request_job.rb`, merge-state pollers |
| External PR ingestion | external-PR jobs, services, workflows, and Steps under their standard directories |
| `.syrus.yml` loading | repository configuration/readers under `app/services/`, operator schema in `config/syrus_docs/syrus_yml.md` |
| Repository browser/diff API | app API controllers and payload services under `app/controllers/api/v1/app/` and `app/services/app/` |
| CLI | `cli/` |
| Desktop | `desktop/` |

Content reads go through `RepositoryContent`; GitHub mutation and metadata APIs
use the focused GitHub clients. See [Repository content](../architecture/repository-content.md).
