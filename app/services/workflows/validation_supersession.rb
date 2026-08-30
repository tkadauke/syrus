require "set"

module Workflows
  class ValidationSupersession
    def self.superseded_by_successful_workflow?(source)
      new(source).superseded_by_successful_workflow?
    end

    def self.successful_validation_workflow_after?(source)
      new(source).successful_validation_workflow_after?
    end

    def self.active_repair_workflow?(workflow)
      active_repair_workflow_trigger_kinds.include?(workflow&.trigger_kind)
    end

    def self.active_repair_workflow_trigger_kinds
      @active_repair_workflow_trigger_kinds ||= WorkDefinitions.workflow_trigger_kinds_for(
        WorkDefinitions.active_repair_work_kinds - WorkDefinitions.layered_auto_repair_suppressed_kinds
      )
    end

    def self.validation_step_kinds
      @validation_step_kinds ||= Step::Kind::ENTRIES
        .select(&:triggers_auto_approval)
        .map(&:kind)
        .to_set + %w[grader_fanout preflight_grader_fanout grade]
    end

    def initialize(source)
      @source = source
    end

    def superseded_by_successful_workflow?
      return false unless source&.job
      return successful_validation_workflow_after? if self.class.active_repair_workflow?(source)

      successful_workflow_after?
    end

    def successful_validation_workflow_after?
      successful_workflows_after_source.any? { |workflow| validation_workflow?(workflow) }
    end

    private

    attr_reader :source

    def successful_workflow_after?
      successful_workflows_after_source.exists?
    end

    def successful_workflows_after_source
      return Workflow.none unless source&.job

      cutoff = source.finished_at || source.created_at
      return Workflow.none unless cutoff

      source.job.workflows
        .where(state: "succeeded")
        .where("created_at > ? OR (created_at = ? AND id > ?)", cutoff, cutoff, source.id)
        .includes(:steps)
    end

    def validation_workflow?(workflow)
      workflow.steps.any? do |step|
        step.succeeded? && self.class.validation_step_kinds.include?(step.kind.to_s)
      end
    end
  end
end
