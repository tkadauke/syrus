# App and Repository Setting Scope Audit

`AppSettingRegistry` is the source of truth for instance setting reachability.
Each definition's `surface` says where an operator can change it:
`admin_settings`, `admin_console`, or blank for Rails-console-only internal
state. `admin_editable` is reserved for `admin_settings`.

Principle: instance-wide settings belong in `AppSetting` when they describe the
deployment itself: credentials, budgets, concurrency, retention, incident
switches, admission policy, and global defaults. Repository settings belong on
`Repository` when they describe how one repository is polled, prepared, graded,
reviewed, repaired, or landed. Several repository behaviors may eventually want
an instance-wide default plus a per-repo override, but that is an explicit
follow-up shape rather than an implicit split across unrelated pages.

## Instance Settings

| Setting | Current scope | Reachability | Kind | Should scope | Decision |
| --- | --- | --- | --- | --- | --- |
| `grade_max_iterations` | instance | Admin Settings | setting | instance default with repo override | Correct: global grader loop default, with `.syrus.yml` override. |
| `adversarial_review_rounds` | instance | Admin Settings | setting | instance default with repo override | Correct: global default; `.syrus.yml` can override per repo. |
| `security_review_rounds` | instance | Admin Settings | setting | instance default with repo override | Correct: global default; `.syrus.yml` can override rounds and add repository criteria. |
| `max_job_failures` | instance | Admin Settings | setting | instance | Correct: retry/auto-pause policy is deployment-wide. |
| `rebase_failure_cooldown_minutes` | instance | Admin Settings | setting | instance | Correct: protects the whole deployment from repeated autonomous rebase churn. |
| `merge_train_max_size` | instance | Admin Settings | setting | instance default with repo override later | Correct for now as a global safety cap; large monorepos may want an override later. |
| `signups_open` | instance | Admin Settings | setting | instance | Correct: deployment access policy. |
| `polling_paused` | instance | Admin Console | setting | instance | Correct: emergency instance kill switch. |
| `telegram_bot_handle` | instance | Admin Settings | setting | instance | Correct: deployment integration identity. |
| `telegram_bot_token` | instance | Admin Settings | setting | instance | Correct: encrypted deployment credential. |
| `telegram_update_offset` | instance | Rails console | internal state | instance | Correct hidden state: platform polling cursor, not operator policy. |
| `discord_bot_token` | instance | Admin Settings | setting | instance | Correct: encrypted deployment credential. |
| `runs_paused` | instance | Admin Console | setting | instance | Correct: emergency instance kill switch. |
| `report_issue_repo_slug` | instance | Admin Settings | setting | instance | Correct: deployment support route. |
| `max_concurrent_agent_runs` | instance | Admin Settings | setting | instance | Correct: cluster-wide resource budget. |
| `max_in_flight_workflows` | instance | Admin Settings | setting | instance | Correct: cluster-wide work-in-progress budget. |
| `prepared_layer_cache_gb` | instance | Admin Settings | setting | instance | Correct: instance-wide default, overridden per worker by `SYRUS_PREPARED_LAYER_CACHE_GB`. |
| `repository_full_poll_interval_hours` | instance | Admin Settings | setting | instance default with repo override later | Correct for now; the backstop cadence is deployment-wide, while unusually large repositories may eventually want overrides. |
| `proactive_rebase_commit_threshold` | instance | Admin Settings | setting | instance default with repo override later | Correct for now; repos with unusual branch protection may want overrides. |
| `show_work_unit_debug` | instance | Admin Settings | setting | instance | Correct: deployment diagnostic visibility. |
| `workflow_admission_control_enabled` | instance | Admin Settings | setting | instance | Correct: opt-in master switch for all soft capacity pacing. |
| `workflow_admission_policy` | instance | Admin Settings | setting | instance | Correct: worker-capacity policy for the deployment. |
| `workflow_admission_control_changed_at` | instance | Rails console | internal state | instance | Correct hidden state: audit stamp maintained by the settings controller. |
| `workflow_admission_control_changed_by_user_id` | instance | Rails console | internal state | instance | Correct hidden state: audit actor maintained by the settings controller. |
| `github_app_id` | instance | Rails console | setup state | instance | Correct hidden state: written by GitHub App setup, not routine policy. |
| `github_app_private_key_pem` | instance | Rails console | setup state | instance | Correct hidden state: encrypted GitHub App credential. |
| `github_app_slug` | instance | Rails console | setup state | instance | Correct hidden state: GitHub App registration detail. |
| `github_app_registered_at` | instance | Rails console | internal state | instance | Correct hidden state: informational registration timestamp. |
| `github_app_installation_sync_started_at` | instance | Rails console | internal state | instance | Correct hidden state: diagnostic sync timestamp. |
| `github_app_installation_sync_succeeded_at` | instance | Rails console | internal state | instance | Correct hidden state: diagnostic sync timestamp. |
| `github_app_installation_sync_duration_ms` | instance | Rails console | internal state | instance | Correct hidden state: diagnostic sync duration. |
| `github_app_installation_sync_records_seen` | instance | Rails console | internal state | instance | Correct hidden state: diagnostic sync count. |
| `github_app_installation_sync_error_class` | instance | Rails console | internal state | instance | Correct hidden state: diagnostic sync error. |
| `github_app_installation_sync_error_message` | instance | Rails console | internal state | instance | Correct hidden state: diagnostic sync error. |
| `video_retention_days` | instance | Admin Settings | setting | instance | Correct: deployment storage retention. |
| `video_storage_budget_mb` | instance | Admin Settings | setting | instance | Correct: deployment storage budget. |
| `chat_coding_workspace_budget_mb` | instance | Admin Settings | setting | instance | Correct: deployment disk budget for worker checkouts. |
| `retention_available_space_override_gb` | instance | Admin Settings | setting | instance | Correct: deployment sizing fallback. |
| `main_concern_report_threshold` | instance | Admin Settings | setting | instance default with repo override later | Correct for now; repos with different main-health noise may eventually want overrides. |
| `workflow_step_resource_profile_input_retention_days` | instance | Admin Settings / Retention Settings | setting | instance | Correct: deployment lookback policy for rebuilding resource profiles. |
| row-retention policies | instance | Retention Settings | `retention_policy_settings` rows | instance | Correct: stable registry keys preserve core and active-plugin choices without adding `app_settings` columns. |

## Repository Policy Columns

| Setting | Current scope | Reachability | Kind | Should scope | Decision |
| --- | --- | --- | --- | --- | --- |
| `agent_provider` | repo | Repository settings | setting | repo | Correct: repo-specific provider routing. |
| `auto_approve_mode` | repo | Repository settings | setting | repo | Correct: repo-specific review/approval risk. |
| `auto_merge_enabled` | repo | Repository settings | setting | repo | Correct: repo-specific landing policy. |
| `distributed_workflow_dag_enabled` | repo | Repository settings | setting | repo | Correct: repo-specific execution behavior. |
| `epic_dependency_policy` | repo | Repository settings | setting | repo | Correct: repo-specific planning/landing shape. |
| `external_pr_ingestion_enabled` | repo | Repository settings | setting | repo | Correct: repo-specific input policy. |
| `feedback_policy` | repo | Repository settings | setting | repo | Correct: repo-specific response policy. |
| `fork_auto_sync_enabled` | repo | Repository settings | setting | repo | Correct: repo-specific fork maintenance. |
| `isolated_repro_dismissal_enabled` | repo | Repository settings | setting | repo | Correct: repo-specific grader interpretation. |
| `known_flaky_failure_dismissal_enabled` | repo | Repository settings | setting | repo | Correct: repo-specific grader interpretation. |
| `pr_check_gate` | repo | Repository settings | setting | repo | Correct: repo-specific landing risk. Replaced the `land_on_inherited_check_failure` boolean; `own_only` is that flag's former `true`. |
| `landing_paused` | repo | Repository detail / repair actions | setting/state | repo | Correct: mutable per-repo landing gate. |
| `main_branch_health_enabled` | repo | Repository settings | setting | repo | Correct: repo-specific health monitoring. |
| `main_branch_repair_auto_approve` | repo | Repository settings | setting | repo | Correct: repo-specific repair approval risk. |
| `main_branch_repair_blocks_work` | repo | Repository settings | setting | repo | Correct: repo-specific broken-main work blocking. |
| `main_branch_repair_enabled` | repo | Repository settings | setting | repo | Correct: repo-specific automatic repair. |
| `new_test_flakiness_gate_enabled` | repo | Repository settings | setting | repo | Correct: repo-specific test-risk policy. |
| `polling_enabled` | repo | Repository settings | setting | repo | Correct: repo-specific issue/PR polling. |
| `pr_cost_footer_enabled` | repo | Repository settings | setting | repo | Correct: repo-specific PR copy behavior. |
| `prepare_enabled` | repo | Repository settings | setting | repo | Correct: repo-specific dependency setup behavior. |
| `review_policy` | repo | Repository settings | setting | repo | Correct: repo-specific human review policy. |
| `trust_clean_rebase_grade` | repo | Repository settings | setting | repo | Correct: repo-specific grader trust policy. |

## Main-Branch Health Compound Policy

"Will a broken default branch stop work?" is answered entirely per repository.
`Repository#breakage_policy` comes from the repository's risk profile
(`RiskProfile`), alongside `main_branch_health_enabled`,
`main_branch_repair_blocks_work`, `main_branch_repair_enabled`,
`main_branch_repair_auto_approve`, and `pr_check_gate`.

This audit originally recorded the breakage policy as an instance setting with
a declared direction of "instance default with an explicit per-repo override
later". The risk-profile postures built that per-repo surface, which left the
instance-wide `AppSetting.main_branch_breakage_policy` as a second, louder
answer to the same question -- and it won: a repository on the `standard`
posture, whose own policy is to keep work moving, had its landing queue paused
anyway because the instance default was `strict`. The instance setting has
been removed; the repository's posture is the only answer.
