class WorkerEnvironmentSmoke
  # Which smoke checks a worker must pass to take one step. The resolver and
  # RunJob intersect this with a worker's failed checks; anything not listed
  # here never keeps a worker from work, which is what makes a failing check
  # fail closed for the workloads that need it and nothing else.
  #
  #   - every Run needs the workflow data root, temp space and git;
  #   - a step kind may declare `worker_checks` (Step::Kind), e.g. the browser
  #     plugin's visual review needs playwright-mcp;
  #   - an agentic step needs its agent provider's CLI, and gh when the
  #     workflow was granted break-glass GitHub access (the only path that
  #     shells out to the worker's own gh);
  #   - a repository's prepare plan needs what RepositoryNeeds recorded the
  #     last time a workspace for it was prepared (bundler and a C toolchain for
  #     `bundle install`, a MySQL client when the lockfile has mysql2, ...).
  module Requirements
    BASE = %w[workflow_data_root tmp git].freeze
    GITHUB_ACCESS_ARTIFACT = "manual_agentic_run_github_access".freeze

    module_function

    def for(workflow:, step:, run: nil)
      checks = BASE.dup
      entry = step_kind_entry(step)
      checks |= declared_step_checks(entry)
      if entry&.agentic
        provider = (run.agent_provider if run.respond_to?(:agent_provider)).presence || workflow&.agent_provider.presence
        checks |= [ Checks.agent_cli_check_name(provider) ] if provider
        checks |= [ "gh" ] if workflow&.artifact(GITHUB_ACCESS_ARTIFACT) == true
      end
      checks | repository_checks(workflow)
    end

    def step_kind_entry(step)
      return nil if step&.kind.blank?

      Step::Kind.fetch(step.kind)
    rescue ArgumentError
      nil
    end

    def declared_step_checks(entry)
      Array(entry&.worker_checks).filter_map { |declared| declared.to_h.transform_keys(&:to_s)["name"].presence&.to_s }
    end

    def repository_checks(workflow)
      repository = workflow&.job&.repository
      return [] unless repository.respond_to?(:worker_environment_requirements)

      Array(repository.worker_environment_requirements).map(&:to_s).reject(&:blank?)
    end
  end
end
