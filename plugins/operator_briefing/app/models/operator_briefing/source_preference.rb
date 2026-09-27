module OperatorBriefing
  class SourcePreference < ApplicationRecord
    self.table_name = "operator_briefing_source_preferences"

    SOURCES = [
      { key: "jobs", label: "Jobs", description: "Recent implementation, repair, and follow-up Jobs.", weight: 1.0 },
      { key: "workflows", label: "Workflows", description: "Workflow progress, failures, retries, and landing state.", weight: 1.0 },
      { key: "notable_changes", label: "Notable changes", description: "Detector facts such as dependencies, migrations, APIs, and security-sensitive paths.", weight: 1.0 },
      { key: "review_findings", label: "Review findings", description: "Adversarial and visual review findings, including overridden findings.", weight: 1.0 },
      { key: "design_doc_threads", label: "Design doc threads", description: "Open design-doc discussions that look blocked on the operator.", weight: 1.0 },
      { key: "spend", label: "Spend", description: "Cost and usage signals when spend data is available.", weight: 1.0 }
    ].freeze
    SOURCE_KEYS = SOURCES.map { |source| source.fetch(:key) }.freeze
    SUGGESTED_BY = %w[system user ai].freeze

    belongs_to :user

    validates :source_key, presence: true, inclusion: { in: SOURCE_KEYS }
    validates :suggested_by, presence: true, inclusion: { in: SUGGESTED_BY }
    validates :weight, numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 5.0 }

    scope :confirmed, -> { where.not(confirmed_at: nil) }
    scope :pending, -> { where(confirmed_at: nil) }

    def self.seed_for_user!(user)
      now = Time.current
      SOURCES.each do |source|
        next if confirmed.where(user: user, source_key: source.fetch(:key)).exists?

        create!(
          user: user,
          source_key: source.fetch(:key),
          enabled: true,
          weight: source.fetch(:weight),
          suggested_by: "system",
          confirmed_at: now
        )
      end
    end

    def self.effective_for_user(user)
      seed_for_user!(user)
      confirmed
        .where(user: user)
        .order(confirmed_at: :desc, id: :desc)
        .each_with_object({}) { |preference, index| index[preference.source_key] ||= preference }
    end

    def self.pending_for_user(user)
      pending.where(user: user, suggested_by: "ai").order(created_at: :desc, id: :desc)
    end

    def self.suggest!(user:, source_key:, enabled:, weight: nil, suggested_by: "ai")
      source = source_for!(source_key)
      create!(
        user: user,
        source_key: source.fetch(:key),
        enabled: enabled,
        weight: weight.presence || source.fetch(:weight),
        suggested_by: suggested_by,
        confirmed_at: nil
      )
    end

    def self.source_for!(source_key)
      SOURCES.find { |source| source.fetch(:key) == source_key.to_s } ||
        raise(ActiveRecord::RecordInvalid.new(new(source_key: source_key)))
    end

    def confirm!
      update!(confirmed_at: Time.current)
    end

    def source_definition
      self.class::SOURCES.find { |source| source.fetch(:key) == source_key }
    end
  end
end
