module Syrus
  class NotableChangeDetection
    EVENT_NAME = "operator_briefing.notable_changes_detected".freeze

    def self.detect!(workflow) = new(workflow).detect!

    def initialize(workflow, git: GitRunner.new)
      @workflow = workflow
      @git = git
    end

    def detect!
      providers = Syrus::PluginRegistry.providers_for(:notable_change_detector)
      return [] if providers.empty?
      return [] unless workspace_path.join(".git").exist?

      facts = providers.flat_map { |provider| facts_for(provider) }.compact
      publish(facts) if facts.any?
      facts
    rescue StandardError => e
      Rails.logger.warn("[NotableChangeDetection] failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
      []
    end

    private

    attr_reader :workflow, :git

    def facts_for(provider)
      Array(provider.detect(
        workflow: workflow,
        diff: diff,
        changed_files: changed_files,
        name_status: name_status,
        workspace_path: workspace_path
      ))
    rescue StandardError => e
      Rails.logger.warn("[NotableChangeDetection] #{provider} failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
      []
    end

    def publish(facts)
      return unless Syrus::Events.known?(EVENT_NAME)

      Syrus::Events.publish(
        EVENT_NAME,
        workflow_id: workflow.id,
        job_id: workflow.job_id,
        repository_id: workflow.job.repository_id,
        facts: facts.map { |fact| fact.to_h.deep_stringify_keys }
      )
    end

    def workspace_path
      @workspace_path ||= WorkflowWorkspace.path_for(workflow)
    end

    def base_ref
      @base_ref ||= WorkflowWorkspace.base_ref_for(workflow.job, workflow: workflow)
    end

    def diff
      @diff ||= git.run("diff", "#{base_ref}...HEAD", chdir: workspace_path.to_s)
    end

    def changed_files
      @changed_files ||= git.run("diff", "--name-only", "#{base_ref}...HEAD", chdir: workspace_path.to_s)
        .split("\n")
        .map(&:strip)
        .reject(&:empty?)
    end

    def name_status
      @name_status ||= git.run("diff", "--name-status", "#{base_ref}...HEAD", chdir: workspace_path.to_s)
        .split("\n")
        .map { |line| line.split("\t") }
        .reject(&:empty?)
    end
  end
end
