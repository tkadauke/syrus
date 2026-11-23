# Main branch health

The Main Branch Health plugin owns the repository settings and observations used to monitor a repository's default branch and, when enabled, coordinate automated repair. Existing repositories keep their settings and health history when upgrading.

Repository settings continue to expose four controls:

- monitor main-branch health;
- enable automated main-branch repair;
- block unrelated work while main is broken; and
- automatically approve repair Jobs.

Monitoring and repair remain opt-in per repository. The instance-wide main-concern report threshold remains available in Admin Settings. The plugin is installed and enabled as part of Syrus so these existing settings and API payloads do not change during the storage move.

This plugin cannot be disabled yet: the health poll and repair workflows are still part of Syrus itself. If the gate, alert and classifier providers are absent, Syrus runs without main-branch gating: workflows start, landing is not paused, and no main-health alerts or classifications are produced.
