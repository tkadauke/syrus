# A typed, append-only change to a running workflow's graph
# (workflow-engine-v3 primitive D / A7).
#
# `Steps::GraderFanout` and `Try`-branch expansion already mutate a live graph;
# this is the same mechanism, made explicit and attributable so an *agent* can
# use it. That is why A7 is deliberately last in the plan: it is only safe once
# provenance (A4), validation, and a capability model exist to bound it.
#
# The guardrails are the plan's, and they are enforced here rather than
# described:
#
#   * **Append-only.** A patch adds nodes. It cannot remove one, so no patch
#     can delete a grader, a publication step, or a landing node -- the checks
#     a workflow exists to satisfy cannot be patched away by the thing being
#     checked.
#   * **No new publication.** A patch cannot introduce a landing or publishing
#     step either. Adding a check is safe; granting yourself the ability to
#     merge is not.
#   * **Attributed.** Every patch records who made it (`agent`, `operator`,
#     `system`), because an unexplained graph is worse than a rigid one.
class WorkflowPatch
  AUTHORS = %w[agent operator system].freeze

  # The typed operations from the plan. Each names what it adds; none removes.
  OPERATIONS = %w[insert_after add_gate bind_grader mark_optional_done].freeze

  Rejected = Class.new(StandardError)

  Result = Data.define(:applied, :reason, :graph) do
    def applied? = applied
  end

  def self.apply!(...) = new(...).apply!

  def initialize(workflow:, operation:, author:, nodes: [], after_kind: nil, reason: nil)
    @workflow = workflow
    @operation = operation.to_s
    @author = author.to_s
    @nodes = Array(nodes)
    @after_kind = after_kind&.to_s
    @reason = reason
  end

  def apply!
    validate!

    patched = patched_graph
    Step.transaction do
      materialize_live_steps!
      @workflow.update!(
        chain_template: patched,
        artifacts: (@workflow.artifacts || {}).merge("workflow_patches" => history + [ record ])
      )
    end

    Result.new(applied: true, reason: nil, graph: patched)
  rescue Rejected => e
    Result.new(applied: false, reason: e.message, graph: @workflow.chain_template)
  end

  private

  def validate!
    raise Rejected, "unknown operation #{@operation.inspect}" unless OPERATIONS.include?(@operation)
    raise Rejected, "unknown author #{@author.inspect}" unless AUTHORS.include?(@author)
    raise Rejected, "no nodes to add" if @nodes.empty? && @operation != "mark_optional_done"
    if @operation == "mark_optional_done"
      raise Rejected, "operation #{@operation.inspect} does not change the live workflow graph"
    end

    # Against the serialized form: a bare "implement" is a node too, and
    # checking the raw input would have silently passed every string.
    unsupported = serialized_nodes.reject { |node| node["type"] == "step" && node["kind"].present? }
    raise Rejected, "runtime workflow patches may only add step nodes" if unsupported.any?

    added = WorkflowTemplates.step_kinds_in(serialized_nodes)
    unknown = added.reject { |kind| Step::Kind.by_kind.key?(kind) }
    raise Rejected, "unknown step kind(s): #{unknown.uniq.sort.join(', ')}" if unknown.any?

    publishing = added & WorkflowTemplates::PROTECTED_STEP_KINDS
    raise Rejected, "may not add publication step(s): #{publishing.uniq.sort.join(', ')}" if publishing.any?

    # The append-only guarantee, checked against the result rather than trusted
    # from the operation name.
    removed = WorkflowTemplates.step_kinds_in(current_graph) - WorkflowTemplates.step_kinds_in(patched_graph)
    raise Rejected, "patches are append-only; would remove #{removed.uniq.sort.join(', ')}" if removed.any?
  end

  def current_graph = Array(@workflow.chain_template)

  def patched_graph
    @patched_graph ||=
      case @operation
      when "mark_optional_done" then current_graph
      when "insert_after", "add_gate", "bind_grader" then insert_after_kind
      end
  end

  def serialized_nodes
    @serialized_nodes ||= @nodes.map do |node|
      node.is_a?(Hash) ? node : { "type" => "step", "kind" => node.to_s }
    end
  end

  # Without a named anchor the nodes go at the end, which is still append-only.
  def insert_after_kind
    serialized = serialized_nodes
    return current_graph + serialized if @after_kind.blank?

    index = current_graph.index { |node| node.is_a?(Hash) && node["kind"] == @after_kind }
    raise Rejected, "no step #{@after_kind.inspect} to insert after" if index.nil?

    current_graph[0..index] + serialized + current_graph[(index + 1)..]
  end

  def history = Array(@workflow.artifacts&.dig("workflow_patches"))

  def materialize_live_steps!
    previous = live_anchor_step
    continuation = previous&.next_step
    ensure_live_insertion_possible!(previous: previous, continuation: continuation)
    insertion_position = previous ? previous.position + 1 : next_position

    @workflow.steps.where("position >= ?", insertion_position).update_all(
      [ "position = position + ?", serialized_nodes.size ]
    )

    new_steps = serialized_nodes.map.with_index do |node, index|
      kind = node.fetch("kind")
      Step.create!(
        workflow: @workflow,
        kind: kind,
        position: insertion_position + index,
        iteration: previous&.iteration || 1,
        loop_id: previous&.loop_id,
        placement_policy: Step::Kind.fetch(kind).placement_policy_for(@workflow.job.repository)
      )
    end

    if previous
      ([ previous ] + new_steps).each_cons(2) { |step, next_step| step.update!(next_step_id: next_step.id) }
    end
    new_steps.last.update!(next_step_id: continuation&.id)
    wire_inserted_step_dependencies!(previous: previous, new_steps: new_steps, continuation: continuation)
    enqueue_ready_inserted_step!(new_steps.first)
  end

  def ensure_live_insertion_possible!(previous:, continuation:)
    raise Rejected, "workflow is not active" unless @workflow.queued? || @workflow.running?
    return unless previous&.terminal?
    return unless continuation&.runs&.exists?

    raise Rejected, "cannot insert after terminal step #{previous.kind.inspect}; its continuation already started"
  end

  def live_anchor_step
    return @workflow.steps.order(:position, :id).last if @after_kind.blank?

    @workflow.steps.where(kind: @after_kind).order(:position, :id).first ||
      raise(Rejected, "no live step #{@after_kind.inspect} to insert after")
  end

  def next_position
    last_position = @workflow.steps.maximum(:position)
    last_position ? last_position + 1 : 0
  end

  def wire_inserted_step_dependencies!(previous:, new_steps:, continuation:)
    return if new_steps.empty?

    if previous
      ([ previous ] + new_steps).each_cons(2) do |dependency, dependent|
        dependent.update!(depends_on_ids: [ dependency.id ])
      end
    end

    return unless continuation

    ids = continuation.depends_on_step_ids
    if ids.empty?
      continuation.update!(depends_on_ids: [ new_steps.last.id ])
    elsif previous && ids.include?(previous.id)
      continuation.update!(depends_on_ids: ids.map { |id| id == previous.id ? new_steps.last.id : id })
    end
  end

  def enqueue_ready_inserted_step!(step)
    return unless step&.queued?
    return if step.runs.exists?
    return unless step.dependencies_settled?

    StepDispatcher.create_run_and_enqueue(step, @workflow)
  end

  def record
    {
      "operation" => @operation,
      "author" => @author,
      "after_kind" => @after_kind,
      "added_kinds" => WorkflowTemplates.step_kinds_in(serialized_nodes),
      "reason" => @reason,
      "applied_at" => Time.current.iso8601
    }.compact
  end
end
