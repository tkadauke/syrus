module App
  class JobEventFields
    def self.for(job)
      new(job).to_h
    end

    def initialize(job)
      @job = job
    end

    def to_h
      start_blocked = start_blocked_data

      {
        id: @job.id,
        entity_revision: @job.entity_revision,
        state: @job.state,
        issue_title: @job.issue_title,
        title: @job.issue_title,
        title_pending: @job.title_pending?,
        issue_body: @job.issue_body,
        pr_mergeable: @job.pr_mergeable,
        pr_mergeable_checked_at: iso8601(@job.pr_mergeable_checked_at),
        updated_at: iso8601(@job.updated_at),
        start_blocked_reason: start_blocked[:reason],
        start_blocked_at: start_blocked[:at],
        start_blocked_next_check_at: start_blocked[:next_check_at],
        start_blocked_count: start_blocked[:count],
        start_blocked_details: start_blocked[:details]
      }
    end

    private

    def start_blocked_data
      work_unit_data = WorkUnits::Ownership.blocked_data_by_job_id([ @job.id ]).fetch(@job.id, {})
      return work_unit_data if work_unit_data[:reason].present?

      workflow_for_start_blocked ? WorkUnits::StartBlock.for(workflow_for_start_blocked).data : {}
    end

    def workflow_for_start_blocked
      @workflow_for_start_blocked ||= WorkUnitMember
        .joins(:work_unit)
        .where(job_id: @job.id, work_units: { state: "blocked" })
        .includes(work_unit: :workflow)
        .reorder("work_units.updated_at DESC", "work_units.id DESC")
        .map { |member| member.work_unit.workflow }
        .compact
        .first
    end

    def iso8601(value)
      value&.iso8601
    end
  end
end
