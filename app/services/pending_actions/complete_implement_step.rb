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
      raise ArgumentError, "branch_name is not a valid branch name" if normalized_branch.present? && !GitBranchName.valid?(normalized_branch)

      if chat_session.local?
        return execute_local_mode_handoff(job, normalized_branch)
      end

      execute_coding_mode_handoff(job, normalized_branch)
    end

    def execute_local_mode_handoff(job, normalized_branch)
      raise ArgumentError, "branch_name is required for Jobs without an existing PR" if job.pr_number.blank? && normalized_branch.blank?

      progress!("Starting local mode handoff for #{job.slug}...")
      workflow = nil
      ApplicationRecord.transaction do
        job.branch_name = normalized_branch if normalized_branch.present?
        job.exit_local_mode!
        job.save!

        workflow = WorkUnits::Launcher.instantiate(kind: "local_mode_handoff", job: job)
      end
      WorkUnits::Launcher.start!(workflow)
      workflow
    end

    def execute_coding_mode_handoff(job, normalized_branch)
      source_branch = coding_source_branch(job, normalized_branch)
      raise ArgumentError, "branch_name is required for Coding Mode handoff" if source_branch.blank?

      progress!("Capturing coding handoff for #{job.slug}...")
      snapshot = CodingHandoffCapture.capture!(
        chat_session: chat_session,
        repository: job.repository,
        user: user,
        source_branch: source_branch,
        handoff_branch: coding_handoff_branch(job),
        allow_existing_branch_update: coding_handoff_updates_existing_branch?(job)
      )

      progress!("Starting coding handoff for #{job.slug}...")
      workflow = nil
      ApplicationRecord.transaction do
        job.branch_name = snapshot.fetch("handoff_branch")
        unless job.complete_coding_handoff!
          raise ArgumentError, "could not start coding handoff"
        end

        workflow = WorkUnits::Launcher.instantiate(
          kind: "coding_handoff",
          job: job,
          artifacts: coding_handoff_artifacts(job, snapshot)
        )
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

    def presentation_label
      "Hand off #{presentation_job_slug}"
    end

    def presentation_detail
      payload["branch_name"].presence&.then { |branch| "Branch: #{branch}" }
    end

    private

    def coding_source_branch(job, normalized_branch)
      normalized_branch.presence ||
        coding_checkout_branch(job).presence ||
        chat_session.coding_checkout_branch.presence ||
        job.branch_name.presence
    end

    def coding_checkout_branch(job)
      ChatWorkspace.coding_checkout_snapshot(chat_session, job.repository)[:current_branch].presence
    rescue StandardError
      nil
    end

    def coding_handoff_branch(job)
      return job.branch_name if coding_handoff_updates_existing_branch?(job)

      "syrus/chat-#{chat_session.id}-job-#{job.id}-handoff-#{action.id}"
    end

    def coding_handoff_updates_existing_branch?(job)
      job.pr_number.present? && job.branch_name.present?
    end

    def coding_handoff_artifacts(job, snapshot)
      {
        "coding_handoff" => snapshot,
        "coding_handoff_chat_id" => chat_session.id,
        "pr_title" => coding_handoff_title(job),
        "pr_body" => coding_handoff_body(job, snapshot),
        "summary" => coding_handoff_summary(job),
        "test_plan" => {
          "steps" => [],
          "notes" => "Submitted from an attached Coding Mode checkout after operator confirmation."
        }
      }
    end

    def coding_handoff_title(job)
      job.issue_title.presence || "Coding Mode handoff"
    end

    def coding_handoff_summary(job)
      job.issue_body.to_s.presence || "Attached Coding Mode handoff."
    end

    def coding_handoff_body(job, snapshot)
      changed_files = Array(snapshot["changed_files"]).presence || [ "(unknown)" ]
      <<~BODY.strip
        #{coding_handoff_summary(job)}

        ## Coding handoff

        Captured attached Coding Mode commits `#{snapshot["base_sha"]}..#{snapshot["head_sha"]}` from `#{snapshot["source_branch"]}` and published handoff branch `#{snapshot["handoff_branch"]}`.

        Changed files:
        #{changed_files.map { |path| "- `#{path}`" }.join("\n")}
      BODY
    end
  end
end
