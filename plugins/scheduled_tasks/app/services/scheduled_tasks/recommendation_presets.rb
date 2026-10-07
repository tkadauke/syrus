module ScheduledTasks
  class RecommendationPresets
    PRESETS = {
      Recommendations::COVERAGE_PRESET => CronTemplate::DEFAULT_TEMPLATES.find do |attrs|
        attrs.fetch(:name) == Recommendations::COVERAGE_TEMPLATE
      end
    }.compact.freeze

    def self.apply(task, preset_id)
      attrs = PRESETS[preset_id.to_s]
      return nil unless attrs

      task.assign_attributes(
        name: attrs.fetch(:name),
        prompt: attrs.fetch(:prompt),
        cron_expression: attrs.fetch(:cron_expression),
        schedule_input: attrs[:schedule_input] || attrs.fetch(:cron_expression),
        pr_pileup_policy: attrs.fetch(:pr_pileup_policy)
      )
      attrs
    end
  end
end
