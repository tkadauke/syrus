class ProviderSession < ApplicationRecord
  belongs_to :resumable, polymorphic: true

  before_validation :mirror_run_id_for_run_resumables
  before_save :sync_transcript_pruned
  belongs_to :run, optional: true

  validates :session_id, presence: true
  validates :provider, presence: true, inclusion: { in: -> { User.agent_providers } }
  validates :resumable, presence: true

  before_validation :default_resumable_from_run

  scope :metadata_only, -> {
    select(:id, :provider, :session_id, :resumable_type, :resumable_id, :run_id, :created_at, :updated_at)
  }

  # Keep captured agent sessions for diagnostics and provider resume
  # rehydration for two weeks after the parent Run reaches a terminal
  # state. After that, ProviderSessionPruneJob deletes them. Active Runs
  # (queued/running) are never pruned.
  RETAIN_AFTER_TERMINAL = 14.days

  scope :prunable, -> {
    for_runs
      .where(runs: { state: Run::TERMINAL_STATES })
      .where("provider_sessions.updated_at < ?", RETAIN_AFTER_TERMINAL.ago)
  }

  # Sessions whose Run already succeeded and still carry a transcript. Kept as
  # a named scope for admin diagnostics; prune deletes the whole row once the
  # terminal retention window expires.
  scope :with_succeeded_transcript, -> {
    for_runs.where(runs: { state: "succeeded" }, transcript_pruned: false)
  }

  scope :for_runs, -> {
    joins("INNER JOIN runs ON runs.id = provider_sessions.resumable_id")
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
  SESSION_ID_PATTERN = /\A[A-Za-z0-9_-]+\z/

  def self.canonical_path_for(home:, cwd:, session_id:)
    encoded = cwd.to_s.gsub(PATH_ENCODE_PATTERN, "-")
    File.join(home, ".claude", "projects", encoded, "#{session_id}.jsonl")
  end

  def self.canonical_transcript_jsonl(home:, cwd:, session_id:)
    normalized = session_id.to_s
    return unless normalized.match?(SESSION_ID_PATTERN)

    path = canonical_path_for(home: home, cwd: cwd, session_id: normalized)
    File.read(path) if File.exist?(path)
  end

  private

  def mirror_run_id_for_run_resumables
    self.run_id = resumable_id if resumable_type == "Run" && resumable_id.present?
  end

  def default_resumable_from_run
    self.resumable ||= run if run
  end

  def sync_transcript_pruned
    self.transcript_pruned = transcript_jsonl.nil?
  end
end
