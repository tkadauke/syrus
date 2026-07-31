module WorkEngine
  class Reconciler
    def self.call(...) = new(...).call

    def self.request(source:, job: nil, workflow: nil, run: nil)
      WorkEngine::ReconcileJob.perform_later(
        source: source.to_s,
        job_id: job&.id,
        workflow_id: workflow&.id,
        run_id: run&.id
      )
    end

    def initialize(source:, job_id: nil, workflow_id: nil, run_id: nil)
      @source = source.to_s
      @job_id = job_id
      @workflow_id = workflow_id
      @run_id = run_id
    end

    def call
      Rails.logger.info(
        "[WorkEngine::Reconciler] requested by #{source}" \
        "#{context_description}"
      )
    end

    private

    attr_reader :source, :job_id, :workflow_id, :run_id

    def context_description
      parts = []
      parts << "job=#{job_id}" if job_id.present?
      parts << "workflow=#{workflow_id}" if workflow_id.present?
      parts << "run=#{run_id}" if run_id.present?
      return "" if parts.empty?

      " (#{parts.join(', ')})"
    end
  end
end
