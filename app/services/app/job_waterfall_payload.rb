module App
  # Non-admin-safe wrapper around ::Timeline::WorkflowWaterfallQuery for the
  # Job detail page's Timeline tab. The underlying query is shared with the
  # admin-only worker_timeline plugin endpoint and always includes
  # worker-identity fields (hostname, pid, worker_storage_key, queue_role);
  # this payload strips them for non-admins so any user who can view the Job
  # gets Step/Run timing without exposing worker topology.
  class JobWaterfallPayload
    WORKER_IDENTITY_FIELDS = %i[ hostname pid worker_storage_key queue_role ].freeze

    def self.build(workflow:, admin:)
      new(workflow: workflow, admin: admin).payload
    end

    def initialize(workflow:, admin:)
      @workflow = workflow
      @admin = admin
    end

    def payload
      result = ::Timeline::WorkflowWaterfallQuery.call(workflow_id: @workflow.id)
      return result if @admin

      {
        workflow: strip_worker_identity(result[:workflow]),
        steps: result[:steps].map { |step| strip_worker_identity(step).merge(runs: step[:runs]) }
      }
    end

    private

    def strip_worker_identity(hash)
      hash.except(*WORKER_IDENTITY_FIELDS)
    end
  end
end
