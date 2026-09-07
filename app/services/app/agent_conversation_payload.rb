module App
  # Explicit node/edge graph of everything that fed into a Job's
  # implementation -- structured data for the Job Detail "Agent
  # Conversation" tab. Walks the Job's Workflows in chronological order
  # and, within each, its Steps (and each agentic Step's Runs), emitting
  # three node kinds:
  #
  #   agent_session      -- one per agentic Run. Role comes structurally
  #                          from Step::Kind/AgentRole, never inferred
  #                          from transcript text.
  #   deterministic_check -- one per non-agentic, outcome-bearing Step
  #                          (grader, format, generate, dependency_audit).
  #   external_trigger    -- one per Workflow whose trigger_kind is
  #                          pr_comment, chat_feedback, or ci_failure,
  #                          sourced from the artifact that actually
  #                          caused the Workflow to fire.
  #
  # Edges within a Workflow are read off Step's own graph edges
  # (depends_on_ids, falling back to the previous_step chain) rather than
  # recomputed from step order -- that is what already encodes
  # grader_fanout/grader_collect fan-out/fan-in, so WorkflowGraphBuilder
  # only has to know how to skip non-node (scaffolding) Steps like
  # `prepare`/`grader_fanout`/`grader_collect`/`pr_open`, resolving
  # through them to whatever real node precedes or follows.
  class AgentConversationPayload
    EXTERNAL_TRIGGER_KINDS = %w[ pr_comment chat_feedback ci_failure ].freeze

    def self.build(job:)
      new(job: job).payload
    end

    def initialize(job:)
      @job = job
    end

    def payload
      { job_id: @job.id, nodes: nodes, edges: edges }
    end

    private

    def workflows
      @workflows ||= @job.workflows.includes(:steps).order(:id).to_a
    end

    def runs_by_step_id
      @runs_by_step_id ||= begin
        step_ids = workflows.flat_map(&:steps).map(&:id)
        Run.where(step_id: step_ids).order(:created_at, :id).group_by(&:step_id)
      end
    end

    def graph
      @graph ||= build_graph
    end

    def nodes = graph[:nodes]
    def edges = graph[:edges]

    def build_graph
      nodes = []
      edges = []
      previous_exit_ids = []

      workflows.each do |workflow|
        workflow_graph = WorkflowGraphBuilder.new(workflow: workflow, runs_by_step_id: runs_by_step_id)

        trigger_node = external_trigger_node(workflow)
        if trigger_node
          nodes << trigger_node
          previous_exit_ids.each { |from_id| edges << { from_id: from_id, to_id: trigger_node[:id] } }
          edges << { from_id: trigger_node[:id], to_id: workflow_graph.first_node_id } if workflow_graph.first_node_id
        end

        nodes.concat(workflow_graph.nodes)
        edges.concat(workflow_graph.edges)
        previous_exit_ids = workflow_graph.exit_node_ids
      end

      { nodes: nodes, edges: edges }
    end

    def external_trigger_node(workflow)
      return nil unless EXTERNAL_TRIGGER_KINDS.include?(workflow.trigger_kind)

      {
        id: "external_trigger-#{workflow.id}",
        kind: "external_trigger",
        workflow_id: workflow.id,
        trigger_kind: workflow.trigger_kind,
        step_id: nil,
        step_kind: nil,
        label: Workflow::TriggerKind.label_for(workflow.trigger_kind),
        state: nil,
        started_at: workflow.started_at&.iso8601,
        finished_at: nil,
        agentic: false,
        summary: ExternalTriggerSource.summary_for(workflow),
        detail: ExternalTriggerSource.detail_for(workflow)
      }
    end

    # Sources the external_trigger node's payload from whatever record
    # actually caused the Workflow to fire -- the artifacts the polling
    # job (or chat feedback submission) stashed on the Workflow when it
    # was instantiated. See Workflows::PrFeedback/ChatFeedback/CiFailure
    # and PollPullRequestJob#enqueue_followup_run/#enqueue_ci_failure_run.
    module ExternalTriggerSource
      module_function

      def detail_for(workflow)
        case workflow.trigger_kind
        when "pr_comment"
          {
            "comments" => Array(workflow.artifact("pr_comments")),
            "feedback_cutoff" => workflow.artifact("feedback_cutoff"),
            "source_handle" => workflow.artifact("pr_feedback_source_handle")
          }
        when "chat_feedback"
          { "feedback" => workflow.artifact("chat_feedback") }
        when "ci_failure"
          {
            "head_sha" => workflow.artifact("head_sha"),
            "base_sha" => workflow.artifact("base_sha"),
            "failed_checks" => Array(workflow.artifact("failed_checks"))
          }
        else
          {}
        end
      end

      def summary_for(workflow)
        case workflow.trigger_kind
        when "pr_comment" then pr_comment_summary(workflow)
        when "chat_feedback" then chat_feedback_summary(workflow)
        when "ci_failure" then ci_failure_summary(workflow)
        end
      end

      def pr_comment_summary(workflow)
        comments = Array(workflow.artifact("pr_comments"))
        cutoff = parse_time(workflow.artifact("feedback_cutoff"))
        new_comments = cutoff ? comments.select { |c| (t = parse_time(c["created_at"])) && t > cutoff } : comments
        latest = (new_comments.presence || comments).last
        handle = workflow.artifact("pr_feedback_source_handle").presence || latest&.dig("author")
        handle.present? ? "PR comment from @#{handle}" : "PR comment"
      end

      def chat_feedback_summary(workflow)
        text = workflow.artifact("chat_feedback").to_s
        text.present? ? "Chat feedback: #{text.truncate(140)}" : "Chat feedback"
      end

      def ci_failure_summary(workflow)
        names = Array(workflow.artifact("failed_checks")).filter_map { |c| c["name"] }
        names.any? ? "CI failure: #{names.join(', ').truncate(140)}" : "CI failure"
      end

      def parse_time(value)
        return nil if value.blank?

        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
    end

    # Per-Workflow Step/Run graph. Skips non-outcome-bearing Steps
    # (prepare, grader_fanout, grader_collect, pr_open, push, ...) as
    # nodes but resolves *through* them so upstream/downstream real
    # nodes still connect -- this is what makes a grader_fanout's
    # materialized `grader` Steps fan out from a single predecessor and
    # fan back into a single successor without any kind-specific code.
    class WorkflowGraphBuilder
      DETERMINISTIC_KINDS = %w[ grader format generate dependency_audit ].freeze
      REVIEW_ARTIFACT_KEYS = {
        "adversarial_review" => "adversarial_review_iterations",
        "visual_review" => "visual_review_iterations"
      }.freeze

      attr_reader :nodes, :edges

      def initialize(workflow:, runs_by_step_id:)
        @workflow = workflow
        @steps = workflow.steps.sort_by(&:position)
        @runs_by_step_id = runs_by_step_id
        @steps_by_id = @steps.index_by(&:id)
        @previous_step_by_id = @steps.index_by(&:next_step_id)
        @chains = {}
        @exit_ids = {}
        @nodes = []
        @edges = []

        build!
      end

      def first_node_id
        @steps.each do |step|
          chain = chain_for(step)
          return chain.first if chain.any?
        end
        nil
      end

      def exit_node_ids
        return [] if @steps.empty?

        exit_node_ids_for(@steps.last)
      end

      private

      def build!
        @steps.each { |step| chain_for(step) }
        @steps.each { |step| add_incoming_edges(step) }
      end

      def chain_for(step)
        @chains[step.id] ||= build_chain(step)
      end

      def build_chain(step)
        if agentic?(step)
          runs = Array(@runs_by_step_id[step.id]).sort_by { |r| [ r.created_at, r.id ] }
          ids = runs.map { |run| add_agent_session_node(step, run) }
          ids.each_cons(2) { |a, b| @edges << { from_id: a, to_id: b } }
          ids
        elsif DETERMINISTIC_KINDS.include?(step.kind)
          [ add_deterministic_check_node(step) ]
        else
          []
        end
      end

      def agentic?(step)
        Step::Kind.by_kind[step.kind]&.agentic || false
      end

      def add_incoming_edges(step)
        chain = chain_for(step)
        return if chain.empty?

        predecessors(step).each do |predecessor|
          exit_node_ids_for(predecessor).each do |from_id|
            @edges << { from_id: from_id, to_id: chain.first }
          end
        end
      end

      def predecessors(step)
        ids = step.depends_on_step_ids
        return ids.filter_map { |id| @steps_by_id[id] } if ids.any?

        previous = @previous_step_by_id[step.id]
        previous ? [ previous ] : []
      end

      def exit_node_ids_for(step)
        @exit_ids[step.id] ||= begin
          chain = chain_for(step)
          chain.any? ? [ chain.last ] : predecessors(step).flat_map { |p| exit_node_ids_for(p) }.uniq
        end
      end

      def add_agent_session_node(step, run)
        id = "agent_session-#{run.id}"
        outcome = review_or_summary_outcome(step, run)

        @nodes << {
          id: id,
          kind: "agent_session",
          workflow_id: @workflow.id,
          trigger_kind: @workflow.trigger_kind,
          step_id: step.id,
          step_kind: step.kind,
          run_id: run.id,
          role: AgentRole.for_step_kind(step.kind),
          agent_provider: run.agent_provider,
          iteration: step.iteration,
          label: Step::Kind.label_for(step.kind),
          state: run.state,
          started_at: run.started_at&.iso8601,
          finished_at: run.finished_at&.iso8601,
          agentic: true,
          summary: outcome[:summary],
          detail: { "verdict" => outcome[:verdict] }.compact
        }
        id
      end

      # submit_summary lands directly on the Run; submit_adversarial_review
      # and submit_visual_review land on the shared Workflow#artifacts
      # iterations array tagged with the submitting Step's iteration --
      # match that back to this Run's Step to find the entry this specific
      # session produced. Same sourcing the agent_activity plugin's
      # AgentActivity::OutcomeSummary uses for its session cards.
      def review_or_summary_outcome(step, run)
        artifact_key = REVIEW_ARTIFACT_KEYS[step.kind]
        if artifact_key
          entry = Array(@workflow.artifact(artifact_key)).find do |candidate|
            candidate.is_a?(Hash) && candidate["iteration"].to_i == step.iteration.to_i
          end
          return { summary: entry["critique"].presence, verdict: entry["verdict"].presence } if entry
        end

        { summary: run.agent_summary.presence, verdict: nil }
      end

      def add_deterministic_check_node(step)
        id = "deterministic_check-#{step.id}"

        @nodes << {
          id: id,
          kind: "deterministic_check",
          workflow_id: @workflow.id,
          trigger_kind: @workflow.trigger_kind,
          step_id: step.id,
          step_kind: step.kind,
          label: deterministic_label(step),
          state: step.state,
          started_at: step.started_at&.iso8601,
          finished_at: step.finished_at&.iso8601,
          agentic: false,
          summary: deterministic_summary(step),
          detail: deterministic_detail(step)
        }
        id
      end

      def deterministic_label(step)
        return step.details["name"] if step.kind == "grader" && step.details["name"].present?

        Step::Kind.label_for(step.kind)
      end

      def deterministic_detail(step)
        return @workflow.artifact("dependency_audit").presence || {} if step.kind == "dependency_audit"

        step.details.presence || {}
      end

      def deterministic_summary(step)
        case step.kind
        when "grader"
          name = step.details["name"] || step.kind
          step.state == "succeeded" ? "#{name} passed" : "#{name} #{step.state}"
        when "format", "generate"
          failures = Array(step.details["#{step.kind}_failures"])
          "#{failures.size} command(s) failed" if failures.any?
        when "dependency_audit"
          audit = @workflow.artifact("dependency_audit")
          return nil unless audit

          results = Array(audit["results"])
          flagged = results.count { |r| !r["clean"] }
          flagged.zero? ? "#{results.size} ecosystem(s) scanned, clean" : "#{flagged} of #{results.size} ecosystem(s) flagged"
        end
      end
    end
  end
end
