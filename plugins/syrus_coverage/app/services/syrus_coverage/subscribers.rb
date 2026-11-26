module SyrusCoverage
  # A closed Job has no further review, so its hit maps go immediately rather
  # than waiting for the TTL.
  class Subscribers
    include Syrus::Host::DomainSubscriber

    def self.subscriptions
      { "job.closed" => :on_job_closed }
    end

    def self.on_job_closed(event)
      job_id = event[:job_id]
      return if job_id.blank?

      Syrus::Host::WorkflowRecord.where(job_id: job_id).find_each do |workflow|
        SyrusCoverage::HitMap.purge_for!(workflow)
      rescue StandardError => e
        Rails.logger.warn("SyrusCoverage::Subscribers: failed to purge hit map for workflow #{workflow.id}: #{e.message}")
      end
    end
  end
end
