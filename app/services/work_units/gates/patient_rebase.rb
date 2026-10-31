module WorkUnits
  module Gates
    class PatientRebase
      REASON = "patient_rebase_waiting_for_active_workflow"
      RETRY_DELAY = 1.minute

      def self.call(work_unit, **) = new(work_unit).call

      def initialize(work_unit)
        @work_unit = work_unit
      end

      def call
        return GateResult.pass unless patient_rebase?

        blocker = blocking_workflow
        return GateResult.pass unless blocker

        GateResult.block(
          reason: REASON,
          retry_at: RETRY_DELAY.from_now,
          details: {
            "blocking_workflow_id" => blocker.id,
            "blocking_workflow_trigger_kind" => blocker.trigger_kind
          }
        )
      end

      private

      attr_reader :work_unit

      def patient_rebase?
        work_unit.kind.in?(RebaseWorkflowSelector::TRIGGER_KINDS) &&
          RebaseRequestOrigin.for(work_unit.workflow&.artifact("requested_by") || "system").patient?
      end

      def blocking_workflow
        workflow = work_unit.workflow
        return unless workflow

        Workflow
          .where(id: WorkUnits::Ownership.active_workflow_ids([ workflow.job_id ], kinds: WorkDefinitions.first_class_work_unit_kinds))
          .where.not(id: workflow.id)
          .order(:created_at, :id)
          .detect do |candidate|
            !candidate.trigger_kind.in?(RebaseWorkflowSelector::TRIGGER_KINDS) &&
              publication_branch_name(candidate) == publication_branch_name(workflow)
          end
      end

      def publication_branch_name(workflow)
        workflow.artifact("publication_branch").presence || workflow.job.branch_name.presence
      end
    end
  end
end
