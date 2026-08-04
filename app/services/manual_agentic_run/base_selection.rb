module ManualAgenticRun
  class BaseSelection
    VALUES = %w[current_pr_branch fresh_checkout failed_workflow_workspace].freeze

    Result = Data.define(:artifacts, :valid_bases, :error, :message) do
      def success? = error.blank?
    end

    def self.for(name)
      {
        "current_pr_branch" => CurrentPrBranch,
        "fresh_checkout" => FreshCheckout,
        "failed_workflow_workspace" => FailedWorkflowWorkspace
      }.fetch(name.to_s, Unknown)
    end

    def initialize(job:, payload:)
      @job = job
      @payload = payload
    end

    def resolve
      raise NotImplementedError
    end

    private

    attr_reader :job, :payload

    def valid_bases
      VALUES
    end

    def error(code, message, bases: valid_bases)
      Result.new(artifacts: {}, valid_bases: bases, error: code, message: message)
    end
  end

  class CurrentPrBranch < BaseSelection
    def resolve
      return error("missing_pr_branch", "current_pr_branch requires the Job to have a branch_name.") if job.branch_name.blank?

      Result.new(
        artifacts: {
          "manual_agentic_run_base" => "current_pr_branch"
        },
        valid_bases: valid_bases,
        error: nil,
        message: "current PR branch #{job.branch_name}"
      )
    end
  end

  class FreshCheckout < BaseSelection
    def resolve
      Result.new(
        artifacts: {
          "manual_agentic_run_base" => "fresh_checkout",
          "skip_existing_branch_checkout" => true
        },
        valid_bases: valid_bases,
        error: nil,
        message: "fresh checkout from #{job.effective_base_branch}"
      )
    end
  end

  class FailedWorkflowWorkspace < BaseSelection
    def resolve
      workflow = selected_workflow
      return unavailable unless workflow

      path = WorkflowWorkspace.path_for(workflow)
      return unavailable unless path.directory? && workflow.cleaned_up_at.nil?

      Result.new(
        artifacts: {
          "manual_agentic_run_base" => "failed_workflow_workspace",
          "failed_workflow_id" => workflow.id,
          "local_source_path" => path.to_s,
          "local_source_branch" => job.branch_name.presence || current_branch(path)
        }.compact,
        valid_bases: valid_bases,
        error: nil,
        message: "failed workflow workspace #{workflow.slug}"
      )
    end

    private

    def selected_workflow
      if payload["failed_workflow_id"].present?
        job.workflows.failed.find_by(id: payload["failed_workflow_id"])
      else
        job.workflows.failed.where(cleaned_up_at: nil).order(created_at: :desc, id: :desc).first
      end
    end

    def unavailable
      error(
        "failed_workflow_workspace_unavailable",
        "Selected failed workflow workspace is unavailable. Use current_pr_branch or fresh_checkout, or select a failed workflow whose workspace is still retained.",
        bases: %w[current_pr_branch fresh_checkout]
      )
    end

    def current_branch(path)
      GitRunner.new.run("rev-parse", "--abbrev-ref", "HEAD", chdir: path.to_s).strip
    rescue StandardError
      nil
    end
  end

  class Unknown < BaseSelection
    def resolve
      error("invalid_base", "base must be one of: #{valid_bases.join(', ')}")
    end
  end
end
