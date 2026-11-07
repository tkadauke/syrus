# Prompts and agent tools

Use these rules for prompt composition, chat turn orientation, and agent invocation limits.

- **`chat_turn_orientation` vs `chat_prompt_injector`.** An injector adds a
  section to the chat *session's* system prompt and is asked once per turn
  whatever arrived. `chat_turn_orientation` is asked about a *specific incoming
  message* and may replace the user's text as the turn's final section — first
  non-nil wins. A walkthrough video is the motivating case: the video is posted
  as a real chat message, and the plugin that owns that message says how the
  agent should open the turn. A provider that claims a message is taking
  responsibility for telling the agent what to do with it.
- **Prompts** all live under `app/services/prompts/`. Core workflow prompt
  classes include
  (`Prompts::Implement`, `Prompts::PrFeedback`, `Prompts::CiFailure`,
  `Prompts::AdversarialReview`, `Prompts::PullRequestSummary`,
  `Prompts::SubmitSummaryInstructions`, `Prompts::TestPlan`,
  `Prompts::ReviewPlan`,
  `Prompts::Rebase`, `Prompts::StackRebase`, `Prompts::PushRebase`,
  `Prompts::LandingFix`,
  `Prompts::ScheduledTask`, `Prompts::DirectJob`, `Prompts::EpicContext`,
  `Prompts::Skill`,
  `VideoWalkthroughs::Prompts::Analysis`, `VideoWalkthroughs::Prompts::Context`,
  `VideoWalkthroughs::Prompts::Report`, `VideoWalkthroughs::Prompts::Segment`).
  Each has a `to_s`. Compose by appending; never inline prompt text in
  jobs/services. Epic-aware prompts append `Prompts::EpicContext` as
  orientation only; it must not expand the current Job's implementation scope.
  `Prompts::Implement`, `Prompts::Rebase`, and `Prompts::StackRebase`
  render their static git-safety and phased-execution instructions through
  `Prompts::SkillLoader` from `.claude/skills/implement/SKILL.md` and
  `.claude/skills/rebase/SKILL.md`; those skill files are live prompt source
  of truth, not duplicate stale documentation.
- **Per-user max-turns** — `User#agent_max_turns` (default 200, range
  0–1000). `0` means no `--max-turns` flag is passed to claude (the
  per-run 90-minute wall-clock timeout still bounds runaway loops). A
  separate 20-minute no-output timeout treats a silent agent subprocess as
  wedged rather than merely slow. Threaded through RunJob → AgentInvocation
  for both regular and rebase runs.
