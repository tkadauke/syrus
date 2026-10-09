# Operator Briefing

Operator Briefing is bundled as a disabled-by-default observability plugin.
When enabled, it adds a top-level `/briefing` sidebar page and a
per-repository `briefing_generate` infrastructure Job kind.

The `/briefing` page is scoped to the signed-in operator. It seeds a
disabled `BriefingSubscription` row for every repository visible to that
operator through repository or team membership so the Settings modal can show
toggles without opting the operator into scheduled work. The page renders one
underline-tab per enabled repository. Subscription and source preferences live
behind the Settings modal, and archived briefings live at `/briefing/history`.
Each Briefing has its own `BRIEFING-<id>` slug so chats, history cards, and
MCP tools can point at the Briefing directly instead of only naming the
underlying Job.

The generation pipeline creates one `Briefing` wrapper per
`briefing_generate` Job and one `BriefingRevision` per generation Workflow.
Generation appends blocks progressively through `submit_briefing_block` and
broadcasts each block over `AppEvents`, so the `/briefing` page refetches
and assembles the new revision while regeneration is still running. The current
live/archived state is the Job state: live briefings are open Jobs, and
archived briefings are closed Jobs. Creating a new briefing for the same
operator and repository closes any previous live briefing with
`briefing_superseded`, freezing its latest revision into history.

Scheduled generation is opt-in and activity-gated. A scheduled pass only
considers operators with at least one enabled repository subscription, then only
creates a new briefing when Jobs or Workflows exist for the repository after
that repository's last closed briefing. Manual regeneration bypasses this
activity gate but does not enable future scheduled generation by itself.
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
  renders `narrative`, `chart`, `image`, `artifact`, and `link_card` blocks.
  Image and artifact blocks are read-only references to existing
  `typed_artifacts` captured by the Workflow being summarized; briefing
  generation never regenerates or uploads fresh artifacts for the main page.
- `operator_briefing_items` stores notable items connected to a briefing.
- `operator_briefing_topics`, `operator_briefing_topic_revisions`, and
  `operator_briefing_topic_links` store durable wiki-style dive pages and their
  links back to the Briefing Jobs that spawned them. Topic rows are scoped to a
  repository and outlive any single briefing period.
- `operator_briefing_subscriptions` stores per-operator repository opt-in.
- `operator_briefing_settings` stores per-operator cadence and generation
  settings.
- `operator_briefing_source_preferences` stores confirmed per-operator source
  preferences plus pending AI suggestions. Defaults are seeded on first payload
  read with every source enabled; AI suggestions remain pending until the
  operator confirms them.
- `operator_briefing_feedbacks` stores explicit thumbs/note feedback on a
  Briefing or item. Creating feedback writes a global `user_pref` memory
  through Agent Memory so future briefing generation reads personalization from
  the same memory system as Agent Insights.

The first "blocked on you" source uses Design Docs workflow MCP access:
`OperatorBriefing::BlockedDesignDocThreads` finds open design-doc threads
visible to an operator whose latest comment is not by that operator, and the
generation agent decides which ones look blocked on that operator.

Narrative blocks may include a small capped set of dive-candidate spans. The
page renders those spans with a dashed underline and marker; clicking one
starts a `briefing_dive` follow-up Workflow on the same live Briefing Job.
Selecting arbitrary text in the briefing surfaces the same "More info"
affordance and starts the same dive workflow. The chain is
`prepare → briefing_dive_investigate → submit_dive_report`; the report step
exposes `read_briefing`, `list_briefing_topics`, `read_briefing_topic`, and
`submit_dive_report` so the agent checks existing topics before creating a new
wiki page. Completed dives use
`OperatorBriefing::InterestSignal.record_dive_completed!` to write the same
kind of global `user_pref` memory with higher confidence than explicit
feedback.

The "Discuss this" action resolves chat in this order: the most recent chat
with confirmed proposal lineage for the briefing Job, then a recent chat with
the repository attached, then a new chat. Every branch adds a short context
message before waking the chat agent.

Generation reads `OperatorBriefing::SourcePreference.effective_for_user` before
building a revision prompt. Disabled sources are called out for the generation
agent, and the user's Agent Memory prompt context is loaded into the same prompt
so explicit feedback and future dive signals use the same personalization input.
