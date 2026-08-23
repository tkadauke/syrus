module JobWorkflowAccessors
  extend ActiveSupport::Concern

  def latest_workflow
    if workflows.loaded?
      workflows.max_by { |wf| [ wf.finished_at.nil? ? 1 : 0, wf.finished_at || Time.zone.at(0), wf.id || 0 ] }
    else
      workflows.reorder(Arel.sql("(finished_at IS NULL) DESC, finished_at DESC, id DESC")).first
    end
  end

  def latest_workflow_id
    return self[:latest_workflow_id] if has_attribute?(:latest_workflow_id)

    latest_workflow&.id
  end

  def latest_workflow_state
    return self[:latest_workflow_state].presence || "queued" if has_attribute?(:latest_workflow_state)

    latest_workflow&.state || "queued"
  end

  def latest_workflow_trigger_kind
    return self[:latest_workflow_trigger_kind] if has_attribute?(:latest_workflow_trigger_kind)

    latest_workflow&.trigger_kind
  end

  def active_workflow_trigger_kind
    WorkUnits::Ownership.active_trigger_kinds_by_job_id([ id ])[id]
  end

  def latest_workflow_created_at
    value = if has_attribute?(:latest_workflow_created_at)
      self[:latest_workflow_created_at]
    else
      latest_workflow&.created_at
    end
    value.is_a?(String) ? Time.zone.parse(value) : value
  end

  def latest_run_id
    return self[:latest_run_id] if has_attribute?(:latest_run_id)

    runs.maximum(:id)
  end
end
