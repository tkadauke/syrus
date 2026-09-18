module PendingActions
  # Confirmed when the operator accepts handoff from a Coding Mode or Local Mode
  # session. Transitions the job out of :coding and fires the appropriate
  # handoff workflow so graders, summarize, and PR automation run.
  class CompleteImplementStep < Base
    action_key "complete_implement_step"

    def execute
      job = action_user_job
      normalized_branch = GitBranchName.normalize(payload["branch_name"])

      raise ArgumentError, "job is not in coding state" unless job.coding?
      raise ArgumentError, "job is not linked to this chat session" unless job.linked_chat_id == chat_session.id
      raise ArgumentError, "complete_implement_step is only available in Coding Mode or Local Mode" unless chat_session.local? || chat_session.coding?
      raise ArgumentError, "Coding Mode is not enabled" if !chat_session.local? && !Feature.coding_mode_enabled?
      raise ArgumentError, "branch_name is required for Jobs without an existing PR" if job.pr_number.blank? && normalized_branch.blank?
      raise ArgumentError, "branch_name is not a valid branch name" if normalized_branch.present? && !GitBranchName.valid?(normalized_branch)

      progress!("Starting #{chat_session.local? ? 'local mode' : 'coding'} handoff for #{job.slug}...")
      workflow = nil
      ApplicationRecord.transaction do
        job.branch_name = normalized_branch if normalized_branch.present?
        if chat_session.local?
          job.exit_local_mode!
          job.save!
        else
          unless job.complete_coding_handoff!
            raise ArgumentError, "could not start coding handoff"
          end
        end

        workflow = WorkUnits::Launcher.instantiate(kind: workflow_kind, job: job)
      end
      WorkUnits::Launcher.start!(workflow)
      workflow
    end

    def execution_label
      "Starting implementation handoff..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      branch_name = GitBranchName.normalize(payload["branch_name"])
      errors.add(:payload, "branch_name is not a valid branch name") if branch_name.present? && !GitBranchName.valid?(branch_name)
    end

    def action_detail
      branch = GitBranchName.normalize(payload["branch_name"])
      [ "job_id: #{payload["job_id"]}", branch.present? ? "branch_name: #{branch}" : nil ].compact.join(", ")
    end

    private

    def workflow_kind
      chat_session.local? ? "local_mode_handoff" : "coding_handoff"
    end
  end
end
