# Operator Briefing

Operator Briefing is bundled as a disabled-by-default observability plugin.
When enabled, it adds a top-level `/briefing` sidebar page and a
per-repository `briefing_generate` infrastructure Job kind.

The `/briefing` page is scoped to the signed-in operator. It seeds a
`BriefingSubscription` row, enabled by default, for every repository visible to
that operator through repository or team membership. The page renders one
underline-tab per enabled repository, plus subscription toggles for opting
repositories in or out.

The generation pipeline creates one `Briefing` wrapper per
`briefing_generate` Job and one `BriefingRevision` per generation Workflow.
Generation appends blocks progressively through `submit_briefing_block` and
broadcasts each block over `AppUserChannel`, so the `/briefing` page refetches
and assembles the new revision while regeneration is still running. The current
live/archived state is the Job state: live briefings are open Jobs, and
archived briefings are closed Jobs. Creating a new briefing for the same
operator and repository closes any previous live briefing with
`briefing_superseded`, freezing its latest revision into history.

Scheduled generation is activity-gated. A scheduled pass only creates a new
briefing when Jobs, Workflows, notable changes, or promoted review findings
exist for the repository after that repository's last closed briefing. Manual
regeneration bypasses this activity gate. `BriefingSettings` stores each
operator's cron-like cadence, budget-gating flag, and optional agent provider
override. Budget-gating is best-effort for now: Syrus tracks spend, but it does
not yet expose a remaining-budget allowance primitive for the plugin to compare
against, so the gate currently records that no hard allowance is available and
fails open.

The plugin also owns these queryable data-layer tables:

- `operator_briefing_review_findings` promotes adversarial and visual review
  verdicts out of Workflow artifact JSON while keeping the artifacts for
  existing Job detail rendering.
- `operator_briefing_workflow_notable_changes` stores facts returned by the
  `:notable_change_detector` extension point.
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

The deterministic detectors cover dependency lockfiles, schema and migration
files, public API surfaces, deleted or weakened tests, overridden review
findings, and security-sensitive paths. Convention-deviation detection flags
changes to repository guidance and convention-sensitive implementation
surfaces as `attention_debt`; later phases can layer an LLM-backed pass over
those candidate facts to decide whether the change truly deviates from the
guidance.

The first "blocked on you" source is
`OperatorBriefing::BlockedDesignDocThreads`: open design-doc threads visible
to an operator whose latest comment is not by that operator.

Narrative blocks may include a small capped set of dive-candidate spans. The
page renders those spans with a dashed underline and marker; clicking one
starts a `briefing_dive` follow-up Workflow on the same live Briefing Job.
Selecting arbitrary text in the briefing surfaces the same "More info"
affordance and starts the same dive workflow. The chain is
`prepare → briefing_dive_investigate → submit_dive_report`; the report step
exposes `list_briefing_topics`, `read_briefing_topic`, and
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
building a revision. Disabled sources are omitted from deterministic cards and
counts, and the user's Agent Memory prompt context is loaded into the revision
payload for the synthesis path so explicit feedback and future dive signals use
the same personalization input.
