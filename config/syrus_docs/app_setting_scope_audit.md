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
| `max_job_failures` | instance | Admin Settings | setting | instance | Correct: retry/auto-pause policy is deployment-wide. |
| `rebase_failure_cooldown_minutes` | instance | Admin Settings | setting | instance | Correct: protects the whole deployment from repeated autonomous rebase churn. |
| `merge_train_enabled` | instance | Admin Console | setting | instance default with repo override later | Correct for now as a global landing mode switch; per-repo override may be useful later. |
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
| `user_daily_spend_budget_usd` | instance | Admin Settings | setting | instance | Correct: deployment spend guardrail. |
| `proactive_rebase_commit_threshold` | instance | Admin Settings | setting | instance default with repo override later | Correct for now; repos with unusual branch protection may want overrides. |
| `show_work_unit_debug` | instance | Admin Settings | setting | instance | Correct: deployment diagnostic visibility. |
| `workflow_admission_control_enabled` | instance | Admin Settings | setting | instance | Correct: global admission kill switch. |
| `workflow_admission_policy` | instance | Admin Settings | setting | instance | Correct: worker-capacity policy for the deployment. |
| `main_branch_breakage_policy` | instance | Admin Settings | setting | instance default with repo override later | Correct for now; main-health behavior already also depends on repo booleans, so a future unified policy surface should make the override explicit. |
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
| `run_diagnostic_retention_days` | instance | Admin Settings / Retention Settings | setting | instance | Correct: deployment data-retention policy for diagnostic rows. |
| `run_diagnostic_archive_before_delete` | instance | Admin Settings / Retention Settings | setting | instance | Correct: deployment archival policy for diagnostic rows. |
| `run_resource_summary_retention_days` | instance | Admin Settings / Retention Settings | setting | instance | Correct: deployment data-retention policy for resource summaries. |
| `worker_host_health_sample_retention_days` | instance | Admin Settings / Retention Settings | setting | instance | Correct: deployment data-retention policy for worker health samples. |
| `work_engine_reconciler_activity_retention_days` | instance | Admin Settings / Retention Settings | setting | instance | Correct: deployment data-retention policy for reconciler events. |
| `work_engine_reconciler_activity_archive_before_delete` | instance | Admin Settings / Retention Settings | setting | instance | Correct: deployment archival policy for reconciler events. |
| `provider_session_retention_days` | instance | Admin Settings / Retention Settings | setting | instance | Correct: deployment data-retention policy for provider sessions. |
| `provider_session_archive_before_delete` | instance | Admin Settings / Retention Settings | setting | instance | Correct: deployment archival policy for provider sessions. |
| `spawned_process_retention_days` | instance | Admin Settings / Retention Settings | setting | instance | Correct: deployment data-retention policy for subprocess inventory. |
| `notification_retention_days` | instance | Admin Settings / Retention Settings | setting | instance | Correct: deployment data-retention policy for notifications. |
| `operational_log_event_retention_hours` | instance | Admin Settings / Retention Settings | setting | instance | Correct: deployment data-retention policy for operational logs. |
| `run_health_snapshot_retention_days` | instance | Admin Settings / Retention Settings | setting | instance | Correct: deployment data-retention policy for Run health snapshots. |
| `run_health_snapshot_archive_before_delete` | instance | Admin Settings / Retention Settings | setting | instance | Correct: deployment archival policy for Run health snapshots. |
| `main_branch_health_check_retention_days` | instance | Admin Settings / Retention Settings | setting | instance | Correct: deployment data-retention policy for main-branch health history. |
| `main_branch_health_check_archive_before_delete` | instance | Admin Settings / Retention Settings | setting | instance | Correct: deployment archival policy for main-branch health history. |
| `workflow_step_resource_profile_retention_days` | instance | Admin Settings / Retention Settings | setting | instance | Correct: deployment data-retention policy for stale resource profiles. |
| `workflow_step_resource_profile_input_retention_days` | instance | Admin Settings / Retention Settings | setting | instance | Correct: deployment lookback policy for rebuilding resource profiles. |
| plugin-provided retention settings | instance | Admin Settings / Retention Settings | setting | instance | Correct: plugin-owned data-retention policy, folded into the registry without core enumerating plugin internals. |

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
| `land_on_inherited_check_failure` | repo | Repository settings | setting | repo | Correct: repo-specific landing risk. |
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

Today, "will a broken default branch stop work?" depends on the instance
`main_branch_breakage_policy` plus repository-level
`main_branch_health_enabled`, `main_branch_repair_blocks_work`,
`main_branch_repair_enabled`, `main_branch_repair_auto_approve`, and
`land_on_inherited_check_failure`. This audit keeps storage unchanged, but the
declared direction is: the breakage policy may become an instance default with
an explicit per-repo override, while the repair and landing booleans remain
repository policy because they describe risk tolerance for one codebase.
