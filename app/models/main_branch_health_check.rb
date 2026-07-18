class MainBranchHealthCheck < ApplicationRecord
  SOURCES = %w[ ci_poll grader_workflow concern_quorum ].freeze
  CONCLUSIVE_GRADER_HEALTH = %w[ healthy broken ].freeze
  SETTLED_CI_HEALTH = %w[ healthy broken not_configured ].freeze
  SETTLED_GRADER_HEALTH = %w[ healthy broken inconclusive ].freeze
  RETAIN_AFTER = 7.days

  belongs_to :repository
  belongs_to :workflow, optional: true

  validates :sha, presence: true
  validates :checked_at, presence: true
  validates :source, presence: true, inclusion: { in: SOURCES }

  scope :recent, -> { order(checked_at: :desc) }
  scope :pruneable, -> { where(checked_at: ..RETAIN_AFTER.ago) }

  def self.conclusive_grader_result_exists?(repository:, sha:)
    where(
      repository: repository,
      sha: sha,
      grader_health: CONCLUSIVE_GRADER_HEALTH
    ).exists?
  end

  def self.settled_ci_result_exists?(repository:, sha:)
    where(
      repository: repository,
      sha: sha,
      ci_health: SETTLED_CI_HEALTH
    ).exists?
  end

  def self.settled_grader_result_exists?(repository:, sha:)
    where(
      repository: repository,
      sha: sha,
      grader_health: SETTLED_GRADER_HEALTH
    ).exists?
  end

  def self.record_ci_poll(repository:, sha:, ci_health:, ci_failed_checks: nil)
    existing = where(repository: repository, sha: sha)
                 .where.not(source: "concern_quorum")
                 .recent
                 .first

    if existing
      existing.update!(ci_health: ci_health, ci_failed_checks: ci_failed_checks, checked_at: Time.current)
      return existing
    end

    create!(
      repository: repository,
      sha: sha,
      checked_at: Time.current,
      ci_health: ci_health,
      grader_health: repository.grader_health,
      ci_failed_checks: ci_failed_checks,
      grader_failed_names: nil,
      source: "ci_poll"
    )
  end

  def self.record_grader_workflow(repository:, sha:, grader_health:, grader_failed_names: nil, workflow: nil)
    existing = where(repository: repository, sha: sha)
                 .where.not(source: "concern_quorum")
                 .recent
                 .first

    if existing
      existing.update!(
        grader_health: grader_health,
        grader_failed_names: grader_failed_names,
        workflow: workflow,
        checked_at: Time.current
      )
      return existing
    end

    create!(
      repository: repository,
      workflow: workflow,
      sha: sha,
      checked_at: Time.current,
      ci_health: repository.ci_health,
      grader_health: grader_health,
      ci_failed_checks: nil,
      grader_failed_names: grader_failed_names,
      source: "grader_workflow"
    )
  end

  def self.record_concern_quorum(repository:, sha:, grader_failed_names: nil)
    create!(
      repository: repository,
      sha: sha,
      checked_at: Time.current,
      ci_health: repository.ci_health,
      grader_health: "broken",
      ci_failed_checks: nil,
      grader_failed_names: grader_failed_names,
      source: "concern_quorum"
    )
  end

end
