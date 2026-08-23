module WorkDefinitions
  class Base
    Scope = Data.define(:type, :id)
    RefMetadata = Data.define(
      :delivery_track,
      :source_repository,
      :source_remote_kind,
      :source_ref,
      :target_repository,
      :target_remote_kind,
      :target_ref
    ) do
      def attributes
        {
          delivery_track: delivery_track,
          source_repository: source_repository,
          source_remote_kind: source_remote_kind,
          source_ref: source_ref,
          target_repository: target_repository,
          target_remote_kind: target_remote_kind,
          target_ref: target_ref
        }
      end
    end
    LANDING_LOCK_KINDS = %w[auto_merge external_pr_merge merge_train landing_validation merge_train_validation].freeze

    class_attribute :kind, instance_accessor: false
    class_attribute :workflow_trigger_kind, instance_accessor: false
    class_attribute :runtime_role, instance_accessor: false
    class_attribute :scope, instance_accessor: false
    class_attribute :parent_kind, instance_accessor: false
    class_attribute :review_publication_step_kinds, instance_accessor: false

    self.parent_kind = nil
    self.review_publication_step_kinds = []

    def self.inherited(subclass)
      super
      WorkDefinitions.reset_registry! if defined?(WorkDefinitions)
    end

    def kind = self.class.kind
    def workflow_trigger_kind = self.class.workflow_trigger_kind
    def runtime_role = self.class.runtime_role
    def scope = self.class.scope
    def parent_kind = self.class.parent_kind
    def review_publication_step_kinds = Array(self.class.review_publication_step_kinds).map(&:to_s)

    def workflow_template
      Workflow::TriggerKind.template_for(workflow_trigger_kind)
    end

    def review_publication_step?(step_kind)
      review_publication_step_kinds.include?(step_kind.to_s)
    end

    def scope_for(job:, artifacts: {}, **)
      case scope
      when "job"
        Scope.new(type: "job", id: job.id)
      when "epic"
        Scope.new(type: "epic", id: job.epic_id)
      when "repository"
        Scope.new(type: "repository", id: job.repository_id)
      else
        Scope.new(type: scope, id: job.id)
      end
    end

    def members_for(job:, artifacts: {}, **)
      [ job ]
    end

    def ref_metadata_for(job:, artifacts: {}, **options)
      RefMetadata.new(
        delivery_track: artifacts.to_h["delivery_track"],
        source_repository: source_repository_for(job),
        source_remote_kind: "repository",
        source_ref: source_ref_for(job, artifacts: artifacts, **options),
        target_repository: target_repository_for(job),
        target_remote_kind: "repository",
        target_ref: target_ref_for(job, artifacts: artifacts, **options)
      )
    end

    def intent_gates = [ WorkIntents::Gates::Dependency ]
    def unit_gates
      [
        WorkUnits::Gates::MainBranchHealth,
        WorkUnits::Gates::ProviderAvailability,
        WorkUnits::Gates::ManualPause,
        WorkUnits::Gates::AdmissionControl
      ]
    end
    def preemption_policy = WorkUnits::PreemptionPolicies::None.new
    def retry_policy = WorkUnits::RetryPolicies::Operator.new
    def blocks_ci_failure? = false
    def active_repair_work? = false
    def retry_workflow_attempt? = false
    def manages_own_job_lifecycle? = infrastructure?
    def landing_lock? = kind.in?(LANDING_LOCK_KINDS)
    def requires_approval? = false
    def requires_epic_readiness? = false

    def lock_keys_for(job:, member_jobs:, artifacts: {}, **)
      keys = member_jobs.map { |member_job| "job:#{member_job.id}" }
      keys << "epic:#{job.epic_id}" if scope == "epic" && job.epic_id.present?
      keys << "repository:#{job.repository_id}" if scope == "repository" && job.repository_id.present?
      keys << "landing:repository:#{job.repository_id}" if landing_lock?
      keys.uniq
    end

    def first_class? = runtime_role == "first_class"
    def child? = runtime_role == "child"
    def infrastructure? = runtime_role == "infrastructure"
    def legacy? = runtime_role == "legacy"

    private

    def source_repository_for(job)
      job.respond_to?(:effective_pr_repository) ? job.effective_pr_repository : job.repository
    end

    def target_repository_for(job)
      job.respond_to?(:effective_target_repository) ? job.effective_target_repository : job.repository
    end

    def source_ref_for(job, artifacts: {}, **)
      artifacts.to_h["source_ref"].presence ||
        artifacts.to_h["head_ref"].presence ||
        artifacts.to_h["branch_name"].presence ||
        (job.branch_name if job.respond_to?(:branch_name))
    end

    def target_ref_for(job, artifacts: {}, **options)
      options[:base_branch].presence ||
        artifacts.to_h["target_ref"].presence ||
        artifacts.to_h["base_branch"].presence ||
        target_repository_for(job)&.default_branch
    end
  end
end
