module WorkDefinitions
  class Base
    Scope = Data.define(:type, :id)
    LANDING_LOCK_KINDS = %w[auto_merge external_pr_merge merge_train landing_validation merge_train_validation].freeze

    class_attribute :kind, instance_accessor: false
    class_attribute :workflow_trigger_kind, instance_accessor: false
    class_attribute :runtime_role, instance_accessor: false
    class_attribute :scope, instance_accessor: false
    class_attribute :parent_kind, instance_accessor: false

    self.parent_kind = nil

    def self.inherited(subclass)
      super
      WorkDefinitions.reset_registry! if defined?(WorkDefinitions)
    end

    def kind = self.class.kind
    def workflow_trigger_kind = self.class.workflow_trigger_kind
    def runtime_role = self.class.runtime_role
    def scope = self.class.scope
    def parent_kind = self.class.parent_kind

    def workflow_template
      Workflow::TriggerKind.template_for(workflow_trigger_kind)
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

    def intent_gates = [ WorkIntents::Gates::Dependency ]
    def unit_gates = [ WorkUnits::Gates::ManualPause ]
    def preemption_policy = WorkUnits::PreemptionPolicies::None.new
    def retry_policy = WorkUnits::RetryPolicies::Operator.new
    def blocks_ci_failure? = false

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

    def landing_lock?
      kind.in?(LANDING_LOCK_KINDS)
    end
  end
end
