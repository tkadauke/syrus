module OperatorBriefing
  class BriefingSettings < ApplicationRecord
    self.table_name = "operator_briefing_settings"
    include ValidatesAgentProvider

    DEFAULT_CADENCE_EXPRESSION = "0 9 * * 1".freeze unless const_defined?(:DEFAULT_CADENCE_EXPRESSION, false)
    # Zone a five-field cadence is interpreted in. UTC keeps a shipped plugin
    # from baking one deployment's zone into every operator's schedule; a
    # per-user zone belongs on the settings row, not in this constant.
    CADENCE_TIMEZONE = "UTC".freeze unless const_defined?(:CADENCE_TIMEZONE, false)

    belongs_to :user
    has_many :subscriptions,
             class_name: "OperatorBriefing::BriefingSubscription",
             foreign_key: :user_id,
             primary_key: :user_id,
             inverse_of: false
    has_many :enabled_subscriptions,
             -> { enabled },
             class_name: "OperatorBriefing::BriefingSubscription",
             foreign_key: :user_id,
             primary_key: :user_id,
             inverse_of: false

    validates :user_id, uniqueness: true
    validates :cadence_expression, presence: true
    validates_agent_provider allow_nil: true
    validate :cadence_expression_is_parseable

    before_validation :set_default_cadence, on: :create
    before_validation :normalize_agent_provider

    def self.for_user(user)
      find_or_create_by!(user: user)
    end

    def due?(now: Time.current)
      window_start = due_window_start(now: now)
      return false unless window_start
      return false if last_scheduled_at.present? && last_scheduled_at >= window_start

      true
    end

    def record_scheduled!(at: Time.current)
      update!(last_scheduled_at: at)
    end

    private

    def set_default_cadence
      self.cadence_expression = DEFAULT_CADENCE_EXPRESSION if cadence_expression.blank?
    end

    def normalize_agent_provider
      self.agent_provider = nil if agent_provider.blank? || agent_provider == "default"
    end

    def cadence_expression_is_parseable
      return if cadence_expression.blank?
      return if cron

      errors.add(:cadence_expression, "must be a valid five-field cron expression")
    end

    def due_window_start(now:)
      parsed = cron
      return nil unless parsed

      previous_time = parsed.previous_time(now + 1.minute)&.to_utc_time
      return nil unless previous_time

      previous_time >= 1.hour.ago(now) ? previous_time : nil
    end

    # Fugit resolves an unqualified cron expression against the *process's*
    # local timezone, so a stored cadence named a different instant depending
    # on how the container happened to be configured: "0 9 * * 1" meant 09:00
    # Eastern where TZ is set and 09:00 UTC in CI, which is why the scheduler
    # spec passed locally and failed there. Pin the zone so one expression
    # means one instant everywhere, matching how ScheduledTasks parses cron.
    # An expression that already carries its own zone is left alone.
    def cron
      expression = cadence_expression.to_s.strip
      return nil if expression.blank?

      expression = "#{expression} #{CADENCE_TIMEZONE}" if expression.split(/\s+/).size == 5
      Fugit::Cron.parse(expression)
    end
  end
end
