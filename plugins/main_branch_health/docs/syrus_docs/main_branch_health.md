# Main branch health

The Main Branch Health plugin owns the repository settings and observations used to monitor a repository's default branch and, when enabled, coordinate automated repair. Existing repositories keep their settings and health history when upgrading.

Repository settings continue to expose four controls:

- monitor main-branch health;
- enable automated main-branch repair;
- block unrelated work while main is broken; and
- automatically approve repair Jobs.

Monitoring and repair remain opt-in per repository. The instance-wide main-concern report threshold remains available in Admin Settings. The plugin is installed and enabled as part of Syrus so these existing settings and API payloads do not change during the storage move.

## What the plugin owns

Everything about main-branch health and repair is provided by this plugin:

- the five-minute health poll, the recorded health checks, and agent-filed concern reports;
- the `main_grader` workflow (grades a landed main commit) and the `main_branch_repair` workflow with its Job, including automatic approval of repair Jobs;
- the work gate that holds workflow starts and landing while main is broken, and the `main_branch_health` start-block reason it produces;
- the failure classifier used by `failures: allow_inherited` graders, the `report_main_concern` agent tool, and the adjudicator that accepts a confirmed concern;
- the stuck-repair and no-progress-repair operator alerts;
- the repository **Health** tab, the dashboard banner for a broken main branch, and the repository settings controls.

## Disabling the plugin

The plugin can be disabled from Admin → Plugins. Syrus then runs without main-branch gating: workflows start normally, landing is not paused, and no health banner, tab, alert or setting is shown. Disabling is refused, with the reason, while a `main_grader` or `main_branch_repair` workflow is queued or running. Stored settings, health history and reports are kept and apply again when the plugin is re-enabled.
