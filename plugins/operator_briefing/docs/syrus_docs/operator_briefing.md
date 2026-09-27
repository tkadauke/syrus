# Operator Briefing

Operator Briefing is bundled as a disabled-by-default observability plugin.
When enabled, it adds a top-level `/briefing` sidebar page and a
per-repository `briefing_generate` infrastructure Job kind.

The `/briefing` page is scoped to the signed-in operator. It seeds a
`BriefingSubscription` row, enabled by default, for every repository visible to
that operator through repository or team membership. The page renders one
underline-tab per enabled repository. Subscription and source preferences live
behind the Settings modal, and archived briefings live at `/briefing/history`.

The generation pipeline creates one `Briefing` wrapper per
`briefing_generate` Job and one `BriefingRevision` per generation Workflow.
The current live/archived state is the Job state: live briefings are open
Jobs, and archived briefings are closed Jobs. Creating a new briefing for the
same operator and repository closes any previous live briefing with
`briefing_superseded`, freezing its latest revision into history.

Scheduled generation is activity-gated. A scheduled pass only creates a new
briefing when Jobs or Workflows exist for the repository after that repository's
last closed briefing. Manual regeneration bypasses this activity gate.
`BriefingSettings` stores each
operator's cron-like cadence, budget-gating flag, and optional agent provider
override. Budget-gating is best-effort for now: Syrus tracks spend, but it does
not yet expose a remaining-budget allowance primitive for the plugin to compare
against, so the gate currently records that no hard allowance is available and
fails open.

The `briefing_generate` Workflow runs `prepare -> briefing_generate_run`. The
generation step is agentic and read-only: the agent uses `read_briefing_git_diff`
for repository changes, `list_briefing_recent_workflows` for completed Workflows in the
briefing window, artifact/transcript tools for evidence, and Design Docs'
`list_design_docs` / `read_design_doc` workflow tools for blocked-on-you
threads. The agent looks directly for notable-change signals in those sources,
including dependencies, schema/migrations, public interfaces, weakened tests,
convention deviations, and security-sensitive paths. It emits typed content
through `submit_briefing_block`.

The plugin owns these data-layer tables:

- `operator_briefing_briefings` wraps the per-repository `briefing_generate` Job.
- `operator_briefing_revisions` stores typed content blocks. This phase
  renders `narrative` and `link_card` blocks only.
- `operator_briefing_items` stores notable items connected to a briefing.
- `operator_briefing_subscriptions` stores per-operator repository opt-in.
- `operator_briefing_settings` stores per-operator cadence and generation
  settings.

The first "blocked on you" source is
Design Docs workflow MCP access: the generation agent reads open design-doc
threads visible to the operator and decides which ones look blocked on that
operator.
