class ClaudeSession < ApplicationRecord
  belongs_to :resumable, polymorphic: true

  before_validation :mirror_run_id_for_run_resumables

  validates :session_id, presence: true
  validates :provider, presence: true, inclusion: { in: User::AGENT_PROVIDERS }

  # Keep sessions for diagnostics for two weeks after the parent Run
  # reaches a terminal state. After that, ClaudeSessionPruneJob deletes
  # them. Active Runs (queued/running) are never pruned.
  RETAIN_AFTER_TERMINAL = 14.days

  scope :prunable, -> {
    for_runs
      .where(runs: { state: %w[ succeeded failed cancelled ] })
      .where("claude_sessions.updated_at < ?", RETAIN_AFTER_TERMINAL.ago)
  }

  # Sessions whose Run already succeeded but still carry a transcript — cleared
  # by the prune job as a belt-and-suspenders sweep (the Run callback handles
  # the common case immediately at transition time).
  scope :with_succeeded_transcript, -> {
    for_runs.where(runs: { state: "succeeded" }).where.not(transcript_jsonl: nil)
  }

  scope :for_runs, -> {
    joins("INNER JOIN runs ON runs.id = claude_sessions.resumable_id")
      .where(resumable_type: "Run")
  }

  # Path Claude Code uses to store its session JSONL on disk:
  # `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`
  # The "project" component is the absolute cwd with every "/"
  # AND every "." replaced by "-". Verified empirically against a
  # running production worker — claude-code encodes both characters
  # to a single dash, so "/.syrus" becomes "--syrus" (double-dash
  # from the slash + dot pair).
  # Example: cwd "/syrus-home/.syrus/workflows/124" →
  #          "-syrus-home--syrus-workflows-124"
  PATH_ENCODE_PATTERN = %r{[/.]}.freeze

  def self.canonical_path_for(home:, cwd:, session_id:)
    encoded = cwd.to_s.gsub(PATH_ENCODE_PATTERN, "-")
    File.join(home, ".claude", "projects", encoded, "#{session_id}.jsonl")
  end

  private

  def mirror_run_id_for_run_resumables
    self.run_id = resumable_id if resumable_type == "Run" && resumable_id.present?
  end
end
