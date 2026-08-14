class CronTemplate < ApplicationRecord
  PR_PILEUP_POLICIES = %w[ skip pile replace ].freeze

  DEFAULT_TEMPLATES = [
    {
      name: "Deduplicate code",
      description: "Finds and consolidates duplicated logic.",
      prompt: <<~PROMPT.strip,
        Survey {{repo_slug}} for duplicated logic — repeated helper methods,
        copy-pasted service objects, near-identical components, or parallel
        implementations of the same behavior. When you find a safe,
        well-scoped duplication to consolidate, extract a shared abstraction
        and update every call site, with tests covering the consolidated
        code path. Keep the change narrowly scoped to one duplication per
        run; don't restructure unrelated code.

        If nothing meets the bar, call submit_summary with a one-line note
        and finish without committing — that's a normal, successful outcome.
      PROMPT
      cron_expression: "0 9 * * 1",
      pr_pileup_policy: "skip"
    },
    {
      name: "Keep documentation up to date",
      description: "Audits docs against recent code changes.",
      prompt: <<~PROMPT.strip,
        Compare recent commits on {{repo_slug}} against its documentation
        (README, top-level agent/contributor guide, and any docs directory)
        to find operator-facing or contributor-facing behavior that has
        drifted out of sync with what's documented. Fix the stale or
        missing documentation for one concrete drift at a time — don't
        rewrite unrelated sections.

        If everything is already current, call submit_summary with a
        one-line note and finish without committing — that's a normal,
        successful outcome.
      PROMPT
      cron_expression: "0 9 * * 3",
      pr_pileup_policy: "skip"
    },
    {
      name: "Increase test coverage",
      description: "Adds tests for under-covered, high-risk code.",
      prompt: <<~PROMPT.strip,
        Find under-tested files in {{repo_slug}} and add focused tests for
        the least-covered, highest-risk code path. Prefer regression-style
        tests that exercise real edge cases over trivial line-count
        padding. Keep the change scoped to one area per run.

        If coverage is already healthy and no under-tested file stands
        out, call submit_summary with a one-line note and finish without
        committing — that's a normal, successful outcome.
      PROMPT
      cron_expression: "0 9 * * 5",
      pr_pileup_policy: "skip"
    }
  ].freeze

  belongs_to :user
  has_many :scheduled_tasks, dependent: :nullify

  # Transient, not persisted — see ScheduledTask#structured_intent.
  attr_accessor :structured_intent

  validates :name, presence: true, length: { maximum: 200 }
  validates :prompt, presence: true
  validates :schedule_expression, presence: true
  validates :pr_pileup_policy, presence: true, inclusion: { in: PR_PILEUP_POLICIES }
  validate  :schedule_expression_is_parseable_and_hourly

  before_validation :canonicalize_recurring_schedule

  scope :enabled_only, -> { where(enabled: true) }

  def self.seed_defaults_for(user)
    DEFAULT_TEMPLATES.each do |attrs|
      user.cron_templates.find_or_create_by!(name: attrs.fetch(:name)) do |template|
        template.assign_attributes(attrs)
      end
    end
  end

  def hourly_cron_expression
    legacy_cron_expression.presence || cron_expression
  end

  def schedule_explanation
    Schedules::RecurringSchedule.explain(schedule_expression, timezone: schedule_timezone)
  rescue ArgumentError
    nil
  end

  def next_fire_at(from: Time.current)
    Schedules::RecurringSchedule.next_fire_at(schedule_expression, timezone: schedule_timezone, from: from)
  rescue ArgumentError
    nil
  end

  private

  def canonicalize_recurring_schedule
    input = schedule_input.presence || cron_expression.presence || legacy_cron_expression.presence || schedule_expression
    result = Schedules::CadencePreview.call(input: input, structured_intent: structured_intent, user: user)
    if result.valid?
      self.schedule_input = input
      self.schedule_format = result.format
      self.schedule_expression = result.expression
      self.schedule_timezone = result.timezone
      self.cron_expression = result.cron_expression
      self.legacy_cron_expression ||= result.cron_expression if result.cron_expression.present?
    else
      self.schedule_expression = nil
      errors.add(:schedule_input, result.errors.to_sentence)
    end
  end

  def schedule_expression_is_parseable_and_hourly
    return if schedule_expression.blank?

    schedule = Schedules::RecurringSchedule.from_expression(schedule_expression, timezone: schedule_timezone)
    schedule.validation_errors.each { |message| errors.add(:schedule_input, message) }
  rescue ArgumentError => e
    errors.add(:schedule_input, e.message)
  end
end
