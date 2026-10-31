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

        jobs = member_jobs(workflow)
        publication_branches = jobs.filter_map { |job| job.branch_name.presence }.to_set
        publication_branches.merge(
          Array(workflow.artifact(StackRebasePlan::STACK_ARTIFACT)).filter_map { |entry| entry["branch_name"].presence }
        )
        publication_branches << workflow.artifact("publication_branch") if workflow.artifact("publication_branch").present?

        Workflow
          .where(id: WorkUnits::Ownership.active_workflow_ids(jobs.map(&:id), kinds: WorkDefinitions.first_class_work_unit_kinds))
          .where.not(id: workflow.id)
          .includes(:job)
          .order(:created_at, :id)
          .detect do |candidate|
            !candidate.trigger_kind.in?(RebaseWorkflowSelector::TRIGGER_KINDS) &&
              publication_branch_name(candidate).in?(publication_branches)
          end
      end

      def member_jobs(workflow)
        work_unit.work_unit_members.includes(:job).order(:id).filter_map(&:job).presence || [ workflow.job ]
      end

      def publication_branch_name(workflow)
        workflow.artifact("publication_branch").presence || workflow.job.branch_name.presence
      end
    end
  end
end
