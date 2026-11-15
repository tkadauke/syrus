module ScheduledTasks
  # A recurring or one-shot agent prompt attached to a repository.
  #
  # Named Task rather than ScheduledTask because a plugin's models are
  # namespaced under its own module; the table keeps the name it had.
  class Task < ApplicationRecord
    self.table_name = "scheduled_tasks"
    include AutoApproveModes
    include AuthorizationCheckpointOrigin

    attribute :schedule_timezone, :string, default: -> { Schedules::RecurringSchedule.server_timezone }

    KINDS = %w[ cron one_shot ].freeze
    STATES = %w[ scheduled paused auto_paused fired ].freeze
    PAUSE_STATES = { "operator" => "paused", "auto" => "auto_paused" }.freeze
    PR_PILEUP_POLICIES = %w[ skip pile replace ].freeze
    AFTER_RUN_POLICIES = %w[ quiet wake ].freeze
    MIN_CRON_INTERVAL = 1.hour

    belongs_to :user
    belongs_to :repository
    belongs_to :cron_template, class_name: "ScheduledTasks::CronTemplate", optional: true
    # The class is Task now, so Rails would infer `task_id`; the column is
    # still `scheduled_task_id` and stays that way until Job Origin step 4.
    has_many :jobs, foreign_key: :scheduled_task_id, inverse_of: false, dependent: :nullify

    # Transient, not persisted. Set by the controller when the operator's
    # schedule_input previously resolved through the LLM cadence fallback, so
    # save-time canonicalization can reuse that structured intent instead of
    # calling the LLM again.
    attr_accessor :structured_intent, :system_destruction

    scope :active, -> { where(archived_at: nil).where(state: %w[ scheduled ]) }
    scope :archived, -> { where.not(archived_at: nil) }
    scope :alive,    -> { where(archived_at: nil) }

    validates :name, presence: true, length: { maximum: 200 }
    validates :prompt, presence: true, if: -> { skill_name.blank? && !system_schedule? }
    validates :system_key, uniqueness: { scope: :coworker_id }, allow_nil: true
    validates :kind, presence: true, inclusion: { in: KINDS }
    validates :state, presence: true, inclusion: { in: STATES }
    validates :pr_pileup_policy, presence: true, inclusion: { in: PR_PILEUP_POLICIES }
    validates :after_run, presence: true, inclusion: { in: AFTER_RUN_POLICIES }
    validates :minute_offset, presence: true,
                              numericality: { only_integer: true, in: 0..59 }
    validates :consecutive_failure_count,
              presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :skill_name, format: { with: Skills::NAME_PATTERN }, allow_blank: true
    validate  :prompt_or_skill
    validate  :system_schedule_attributes_are_owned_by_code, on: :update
    before_destroy :prevent_system_schedule_destruction

    validates :schedule_expression, presence: true, if: :cron?
    validates :fire_at,         presence: true, if: :one_shot?
    validate  :schedule_expression_is_parseable_and_hourly, if: :cron?
    validate  :fire_at_is_in_the_future_at_create,      if: -> { one_shot? && new_record? }
    validate  :skill_args_match_parameter_schema, if: -> { skill_name.present? && repository.present? }

    before_validation :normalize_task_source
    before_validation :canonicalize_recurring_schedule
    before_validation :seed_minute_offset_for_cron, on: :create

    def cron?
      kind == "cron"
    end

    def one_shot?
      kind == "one_shot"
    end

    def archived?
      archived_at.present?
    end

    def active?
      !archived? && state == "scheduled"
    end

    def paused?
      state == "paused"
    end

    def auto_paused?
      state == "auto_paused"
    end

    def fired?
      state == "fired"
    end

    def skill_task?
      skill_name.present?
    end

    def system_schedule? = system_key.present?

    def prompt_for(target_date: nil)
      return prompt unless system_schedule?

      ScheduledTasks::SystemSchedules.fetch(system_key).new.prompt(task: self, target_date: target_date)
    end

    # Compatibility alias for API consumers that still read the historical
    # hourly_cron_expression field. Scheduling itself uses schedule_expression.
    def hourly_cron_expression
      return nil unless cron?
      legacy_cron_expression.presence || cron_expression
    end

    def display_cron_expression
      cron? ? hourly_cron_expression : nil
    end

    def schedule_explanation
      return nil unless cron? && schedule_expression.present?

      Schedules::RecurringSchedule.explain(schedule_expression, timezone: schedule_timezone)
    rescue ArgumentError
      nil
    end

    # When does this task fire next, after `from`? Returns nil if it
    # won't (paused, archived, fired one_shot, malformed cron). For
    # cron tasks, the next hourly window is returned once the scheduled
    # minute has arrived.
    def next_fire_at(from: Time.current)
      return nil unless active?

      if one_shot?
        fire_at && fire_at > from ? fire_at : nil
      else
        current_window = scheduled_fire_window_start(now: from)
        return current_window if current_window.present? && !fired_in_window?(current_window)

        Schedules::RecurringSchedule.next_fire_at(schedule_expression, timezone: schedule_timezone, from: from)
      end
    rescue ArgumentError
      nil
    end

    # Has this task's current fire window arrived? Cron windows are one
    # hour wide and keyed by their UTC hour, so a poller that runs several
    # times during the same hour still sees only one intended fire.
    def due?(now: Time.current)
      return false unless active?

      if one_shot?
        fire_at.present? && fire_at <= now
      else
        window_start = scheduled_fire_window_start(now: now)
        scheduled_due = window_start.present? && !fired_in_window?(window_start)
        scheduled_due || system_catch_up_due?(now: now)
      end
    end

    def fire_window_start(now: Time.current, manual: false)
      if one_shot?
        fire_at || now
      elsif manual
        now.utc.change(min: 0, sec: 0, usec: 0)
      else
        scheduled_fire_window_start(now: now) || system_catch_up_window_start(now: now)
      end
    end

    def fired_in_window?(window_start)
      return false if last_fired_at.blank? || window_start.blank?
      last_fired_at >= window_start && last_fired_at < window_start + 1.hour
    end

    # Does this task already have a Job whose PR is still open on GitHub
    # from a prior fire? Used by pr_pileup_policy=skip to short-circuit.
    def has_open_pr?
      jobs.open_threads.with_pr.exists?
    end

    # Most recent Job's still-open PR ids — used by pr_pileup_policy=replace
    # to close them out before opening a fresh one.
    def open_pr_jobs
      jobs.open_threads.with_pr
    end

    # The most recently created Job from this task that opened a PR.
    # Used by Prompts::ScheduledTask to tell the agent what happened last time.
    def last_pr_job
      jobs.with_pr.order(created_at: :desc).first
    end

    def soft_delete!
      raise ActiveRecord::RecordInvalid, self if system_schedule_error!(:base, "System schedules cannot be deleted.")

      update!(archived_at: Time.current)
    end

    def destroy_as_system!
      self.system_destruction = true
      destroy!
    ensure
      self.system_destruction = false
    end

    def record_system_result!(date:, result:, reason: nil)
      with_lock do
        previous = Array(system_result_history).find { |item| item["date"] == date.iso8601 }
        entry = previous.to_h.slice("alerted_at").merge(
          "date" => date.iso8601, "result" => result.to_s, "reason" => reason,
          "recorded_at" => Time.current.iso8601
        )
        history = Array(system_result_history).reject { |item| item["date"] == entry["date"] }
        attributes = {
          system_result_history: (history << entry).last(31),
          last_system_result: result,
          last_system_result_on: date,
          last_system_result_reason: reason
        }
        attributes[:last_journaled_on] = [ last_journaled_on, date ].compact.max unless result.to_s == "failed"
        update!(attributes)
      end
    end

    def pause!(reason: "operator")
      update!(state: PAUSE_STATES.fetch(reason))
    end

    def resume!
      update!(state: "scheduled", consecutive_failure_count: 0)
    end

    def mark_fired_one_shot!
      update!(state: "fired")
    end

    def record_fire!(at: Time.current)
      update!(last_fired_at: at)
    end

    def record_success!(at: Time.current)
      update!(last_successful_fire_at: at, consecutive_failure_count: 0)
    end

    def record_failure!
      increment!(:consecutive_failure_count)
      return if archived? || system_schedule?
      if consecutive_failure_count >= AppSetting.max_job_failures
        pause!(reason: "auto")
      end
    end

    def record_fire_failure!(error, at: Time.current)
      record_failure!
      return unless system_schedule?

      # A raised handler is still an attempted fire. Stamping the attempt keeps
      # the minute poller from hammering the same broken system schedule for the
      # rest of its hourly window; the definition's catch-up policy controls
      # subsequent retries.
      record_fire!(at: at)
      date = system_schedule_definition.failure_date(task: self, now: at)
      return unless date

      reason = fire_failure_reason(error)
      record_system_result!(date: date, result: "failed", reason: reason)
      system_schedule_definition.failure_recorded(task: self, date:, reason:)
    end

    private

    # Class, message and the first backtrace frame (file:line), so the failing
    # line is visible durably after the operational logs have rotated.
    def fire_failure_reason(error)
      message = error.message.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "\uFFFD").scrub("\uFFFD")
      reason = "#{error.class}: #{CommandRedactor.redact(message)}".truncate(800)
      frame = error.backtrace&.first
      return reason unless frame

      frame = frame.to_s.dup.force_encoding(Encoding::UTF_8).scrub("\uFFFD")
      frame = frame.delete_prefix("#{Rails.root}/")
      "#{reason} (at #{CommandRedactor.redact(frame)})".truncate(1_000)
    end

    def prevent_system_schedule_destruction
      throw(:abort) if !system_destruction && system_schedule_error!(:base, "System schedules cannot be deleted.")
    end

    def system_schedule_attributes_are_owned_by_code
      return unless system_schedule? || system_key_was.present?

      protected_changes = changes_to_save.keys & %w[system_key prompt kind name coworker_id user_id repository_id after_run]
      errors.add(:base, "System schedule identity and prompt are owned by Syrus.") if protected_changes.any?
    end

    def system_schedule_error!(attribute, message)
      return false unless system_schedule?

      errors.add(attribute, message)
      true
    end

    def normalize_task_source
      self.skill_args = {} if skill_name.blank?
    end

    def scheduled_fire_window_start(now: Time.current)
      Schedules::RecurringSchedule.due_window_start(schedule_expression, timezone: schedule_timezone, now: now)
    rescue ArgumentError
      nil
    end

    def system_catch_up_due?(now: Time.current)
      system_schedule? && system_schedule_definition.catch_up_due?(task: self, now: now)
    rescue ArgumentError
      false
    end

    def system_catch_up_window_start(now: Time.current)
      return unless system_catch_up_due?(now: now)

      now.utc.change(min: 0, sec: 0, usec: 0)
    end

    def system_schedule_definition
      ScheduledTasks::SystemSchedules.fetch(system_key).new
    end

    def seed_minute_offset_for_cron
      return unless cron?
      return if minute_offset_changed? && !minute_offset.nil?

      self.minute_offset = SecureRandom.random_number(60)
    end

    def canonicalize_recurring_schedule
      return unless cron?

      input = schedule_input.presence || cron_expression.presence || legacy_cron_expression.presence || schedule_expression
      result = Schedules::CadencePreview.call(input: input, structured_intent: structured_intent, timezone: schedule_timezone, user: user)
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

    def fire_at_is_in_the_future_at_create
      return if fire_at.blank?
      errors.add(:fire_at, "must be in the future") if fire_at <= Time.current
    end

    def skill_args_match_parameter_schema
      resolution = Skills.for(repository: repository, name: skill_name, user: user)
      Skills::ParameterSchema.validate!(resolution.definition.parameters, skill_args.presence || {})
    rescue Skills::NotFoundError, ArgumentError, Skills::SkillMarkdown::ParseError, Skills::ParameterSchema::ParseError => e
      errors.add(:skill_name, "could not be resolved: #{e.message}")
    rescue Skills::ParameterSchema::ValidationError => e
      errors.add(:skill_args, e.message)
    end

    def prompt_or_skill
      return unless prompt.present? && skill_name.present?

      errors.add(:base, "Choose either a prompt or a skill, not both")
    end
  end
end
