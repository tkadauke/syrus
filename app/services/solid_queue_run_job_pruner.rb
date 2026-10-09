class SolidQueueRunJobPruner
  def self.delete_pending_for_run!(run_id, include_claimed: false)
    new(run_id: run_id, include_claimed: include_claimed).delete_pending!
  end

  def self.delete_job_ids!(job_ids)
    ids = Array(job_ids).map(&:to_i).select(&:positive?)
    return 0 if ids.empty?

    delete_solid_queue_rows!(ids)
  end

  def initialize(run_id:, include_claimed: false)
    @run_id = run_id.to_i
    @include_claimed = include_claimed
  end

  def delete_pending!
    return 0 unless run_id.positive?

    ids = matching_job_ids
    return 0 if ids.empty?

    self.class.delete_job_ids!(ids)
  rescue NameError, ActiveRecord::StatementInvalid, ActiveRecord::NoDatabaseError => e
    Rails.logger.warn("[SolidQueueRunJobPruner] failed to prune pending RunJob rows for Run ##{run_id}: #{e.class}: #{e.message}")
    0
  end

  private

  attr_reader :run_id, :include_claimed

  def matching_job_ids
    scope = SolidQueue::Job
      .where(class_name: "RunJob", finished_at: nil)

    scope = scope.where.not(id: SolidQueue::ClaimedExecution.select(:job_id)) unless include_claimed

    if mysql?
      scope.where("JSON_UNQUOTE(JSON_EXTRACT(arguments, '$.arguments')) = ?", JSON.generate([ run_id ])).pluck(:id)
    else
      scope.limit(2_000).filter_map do |job|
        job.id if active_job_arguments(job.arguments) == [ run_id ]
      end
    end
  end

  def mysql?
    SolidQueue::Job.connection.adapter_name.downcase.include?("mysql")
  end

  def active_job_arguments(arguments)
    payload = arguments.is_a?(String) ? JSON.parse(arguments) : arguments
    args = payload.is_a?(Hash) ? (payload["arguments"] || payload[:arguments]) : payload
    args.is_a?(Array) ? args : nil
  rescue JSON::ParserError, TypeError
    nil
  end

  def self.delete_solid_queue_rows!(ids)
    SolidQueue::ReadyExecution.where(job_id: ids).delete_all if defined?(SolidQueue::ReadyExecution)
    SolidQueue::ScheduledExecution.where(job_id: ids).delete_all if defined?(SolidQueue::ScheduledExecution)
    SolidQueue::ClaimedExecution.where(job_id: ids).delete_all if defined?(SolidQueue::ClaimedExecution)
    SolidQueue::BlockedExecution.where(job_id: ids).delete_all if defined?(SolidQueue::BlockedExecution)
    SolidQueue::FailedExecution.where(job_id: ids).delete_all if defined?(SolidQueue::FailedExecution)
    SolidQueue::Job.where(id: ids).delete_all
  end
end
