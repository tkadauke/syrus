module Steps
  # Materializes per-grader Steps from .syrus.yml. Runs after each
  # `implement` (or equivalent) Step inside the workflow's grade
  # loop; inserts one `grader` Step per configured grader between
  # itself and the next Step in the chain (which is the
  # `grader_collect` Step that aggregates the iteration's outcome).
  #
  # Why this exists: the chain is built at workflow-instantiate
  # time, before the workspace exists. The list of graders comes
  # from `.syrus.yml` in the cloned repo, which is only readable
  # AFTER Steps::Prepare runs. So the static chain has a placeholder
  # `grader_fanout` Step that, at execution time, reads the plan
  # and dynamically inserts the actual graders. Each grader Step's
  # definition (name, command, description, required, timeout)
  # is snapshotted onto its Step#details — immutable for that Step,
  # immune to `.syrus.yml` evolution.
  class GraderFanout < Base
    def call
      workspace.setup
      plan = RepoGradePlan.for(workspace.path)
      record_plan_source!(plan)
      apply_loop_max_iterations!(plan.max_iterations)

      log("[grader_fanout] source: #{plan.source}")
      log("[grader_fanout] note: #{plan.note}") if plan.note

      if plan.graders.empty?
        log("[grader_fanout] no graders configured — collect Step will pass through")
        return
      end

      materialize_grader_steps!(plan.graders)
      log("[grader_fanout] materialized #{plan.graders.size} grader Step(s)")
    end

    private

    def record_plan_source!(plan)
      workflow.set_artifact!("grade_plan_source", plan.source)
    end

    def apply_loop_max_iterations!(max_iterations)
      template = Array(workflow.chain_template).map(&:dup)
      loop_node = template.find { |node| loop_node_for_current_step?(node) }
      return unless loop_node

      loop_node["max_iterations"] = max_iterations
      workflow.update!(chain_template: template)
    end

    def loop_node_for_current_step?(node)
      node["type"] == "loop" &&
        Array(node["steps"]).map(&:to_s).include?(step.kind)
    end

    # Insert one Step per grader between this fanout Step and its
    # current next_step (which is the iteration's grader_collect).
    # Bump positions of everything past the insertion point to
    # make room.
    def materialize_grader_steps!(graders)
      continuation = step.next_step
      insertion_position = step.position + 1
      offset = graders.size

      Step.transaction do
        workflow.steps.where("position >= ?", insertion_position).update_all(
          [ "position = position + ?", offset ]
        )

        new_steps = graders.each_with_index.map do |grader, index|
          Step.create!(
            workflow: workflow,
            kind: "grader",
            position: insertion_position + index,
            iteration: step.iteration,
            loop_id: step.loop_id,
            details: {
              "name" => grader.name,
              "command" => grader.command,
              "description" => grader.description,
              "required" => grader.required,
              "timeout_minutes" => grader.timeout_minutes
            }
          )
        end

        # Chain the new Steps in order and re-link the last one to
        # the original continuation (grader_collect).
        ([ step ] + new_steps).each_cons(2) { |a, b| a.update!(next_step_id: b.id) }
        new_steps.last.update!(next_step_id: continuation&.id)
      end
    end
  end
end
