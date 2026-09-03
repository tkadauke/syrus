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

  def self.canonical_path_for(home:, cwd:, session_id:)
    claude_session_paths.canonical_path_for(home: home, cwd: cwd, session_id: session_id)
  end

  def self.canonical_transcript_jsonl(home:, cwd:, session_id:)
    claude_session_paths.canonical_transcript_jsonl(home: home, cwd: cwd, session_id: session_id)
  end

  def self.canonical_subagents_dir_for(home:, cwd:, session_id:)
    claude_session_paths.canonical_subagents_dir_for(home: home, cwd: cwd, session_id: session_id)
  end

  private

  def self.claude_session_paths
    "ClaudeAgent::SessionPaths".safe_constantize ||
      raise(ChatProviders::ConfigurationError, "Claude provider plugin is not installed")
  end

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
