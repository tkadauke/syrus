module Coworkers
  class RunStep < ::Steps::Base
    def call
      workspace.setup
      run.update!(prompt: prompt) if run.prompt.blank?
      log("invoking coworker for background run (#{workflow.slug})")
      result = with_execution_workload { run_agent(prompt: run.prompt) }
      run.update!(agent_summary: result.final_text.to_s.strip.presence)
    end

    private

    def with_execution_workload
      previous = Thread.current[:syrus_execution_workload_policy]
      Thread.current[:syrus_execution_workload_policy] = Coworkers::ExecutionWorkloadPolicy.new
      yield
    ensure
      Thread.current[:syrus_execution_workload_policy] = previous
    end

    def prompt
      <<~TEXT.strip
        You are running an unattended background task as a persistent coworker.

        #{job.issue_body.presence || job.issue_title}

        Work in the checked-out coworker workspace. Interactive-only tools are unavailable. Any action requiring owner confirmation must be queued for approval instead of waiting for a live response.
      TEXT
    end
  end
end
