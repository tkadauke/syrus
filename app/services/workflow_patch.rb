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
    @workflow.update!(
      chain_template: patched,
      artifacts: (@workflow.artifacts || {}).merge("workflow_patches" => history + [ record ])
    )

    Result.new(applied: true, reason: nil, graph: patched)
  rescue Rejected => e
    Result.new(applied: false, reason: e.message, graph: @workflow.chain_template)
  end

  private

  def validate!
    raise Rejected, "unknown operation #{@operation.inspect}" unless OPERATIONS.include?(@operation)
    raise Rejected, "unknown author #{@author.inspect}" unless AUTHORS.include?(@author)
    raise Rejected, "no nodes to add" if @nodes.empty? && @operation != "mark_optional_done"

    # Against the serialized form: a bare "implement" is a node too, and
    # checking the raw input would have silently passed every string.
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
