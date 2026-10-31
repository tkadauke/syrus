module SdlcPipeline
  class Stage
    Entry = Data.define(:key, :label, :kind, :matcher)

    LIFECYCLE = [
      Entry.new(key: "triaging", label: "Triaging", kind: "lifecycle", matcher: ->(job) { job.needs_triage? || job.triaging? }),
      Entry.new(key: "ready", label: "Ready", kind: "lifecycle", matcher: ->(job) { job.backlog? || job.blocked_by_epic? || job.queued? }),
      Entry.new(key: "implementing", label: "Implementing", kind: "lifecycle", matcher: ->(job) { job.running? || job.coding? || job.failed? }),
      Entry.new(key: "review", label: "Review", kind: "lifecycle", matcher: ->(job) { job.implemented? }),
      Entry.new(key: "landing", label: "Landing", kind: "lifecycle", matcher: ->(job) { job.approved? || job.landing? }),
      Entry.new(
        key: "landed",
        label: "Landed",
        kind: "lifecycle",
        matcher: ->(job) { job.landed_sha.present? || job.no_change_needed? || (job.closed? && Epic::SUCCESSFUL_JOB_CLOSURE_REASONS.include?(job.closure_reason)) }
      )
    ].freeze

    def self.entries(deployment_stages)
      LIFECYCLE + deployment_stages.map do |stage|
        Entry.new(
          key: "deployment:#{stage.name}",
          label: stage.label,
          kind: "deployment",
          matcher: ->(job) { job.deployment_stage_statuses.any? { |status| status.stage_name == stage.name } }
        )
      end
    end

    def self.for(job, entries)
      entries.reverse_each.find { |entry| entry.matcher.call(job) }
    end
  end
end
