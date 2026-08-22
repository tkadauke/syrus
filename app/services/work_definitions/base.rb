module WorkDefinitions
  class Base
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

    def first_class? = runtime_role == "first_class"
    def child? = runtime_role == "child"
    def infrastructure? = runtime_role == "infrastructure"
    def legacy? = runtime_role == "legacy"
  end
end
