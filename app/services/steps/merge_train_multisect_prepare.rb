module Steps
  class MergeTrainMultisectPrepare < Base
    include MergeTrainStep

    def call
      members = merge_train.members.includes(:job).order(:position).to_a
      selector = MergeTrainMultisect.focused_selector(workflow)
      width = MergeTrainMultisect.section_width_for(repository)
      sections = MergeTrainMultisect.partition(members, section_width: width)
      payload = {
        "status" => "preparing",
        "merge_train_id" => merge_train.id,
        "candidate_members" => MergeTrainMultisect.members_payload(members),
        "failing_set" => selector,
        "base_sha" => workflow.artifact("merge_train_base_sha"),
        "integration_sha" => merge_train.integration_sha,
        "integration_branch" => merge_train.integration_branch,
        "section_width" => width,
        "section_width_source" => repository.merge_train_multisect_section_width.present? ? "repository" : "default",
        "planned_sections" => sections.each_with_index.map { |section, index| section_payload(section, index, last_index: sections.size - 1) },
        "prepared_at" => Time.current.iso8601
      }
      workflow.set_artifact!(MergeTrainMultisect::ARTIFACT_KEY, payload)
      step.update!(details: step.details.to_h.merge(payload))
      log("[merge_train_multisect_prepare] planned #{sections.size} section(s) with width #{width}")

      return abort!("not_enough_members", payload) if members.size < 2
      return abort!("empty_focused_selector", payload) if selector.empty?
      return abort!("flaky_oracle", payload.merge("determinism" => determinism_payload)) unless determinism_reproducible?

      MergeTrainMultisectWorkflow.append_collect_with_evaluations!(
        after_step: step,
        collect_details: { phase: "oracle", round: 0 },
        evaluations: [
          evaluation_details(members: members, role: "oracle", round: 0, section_index: 0, source_snapshot: source_snapshot_details)
        ]
      )
    end

    private

    def section_payload(section, index, last_index:)
      {
        "index" => index,
        "members" => MergeTrainMultisect.members_payload(section),
        "omitted" => index == last_index
      }
    end

    def determinism_gate
      @determinism_gate ||= MergeTrainMultisect::DeterminismGate.new(workflow: workflow, log: method(:log))
    end

    def determinism_reproducible?
      @determinism_reproducible = determinism_gate.reproducible?
    end

    def determinism_payload
      determinism_gate.payload
    end

    def abort!(reason, payload)
      record = payload.merge("status" => "aborted", "reason" => reason, "recorded_at" => Time.current.iso8601)
      workflow.set_artifact!(MergeTrainMultisect::ARTIFACT_KEY, record)
      workflow.set_artifact!(MergeTrainMultisectWorkflow::COMPLETED_ARTIFACT_KEY, record)
      log("[merge_train_multisect_prepare] aborted: #{reason}")
      fail_with!(:grader_failure, "merge_train_multisect: #{reason}", evidence: { reason: reason })
    end

    def evaluation_details(members:, role:, round:, section_index:, source_snapshot:)
      {
        role: role,
        round: round,
        section_index: section_index,
        member_ids: members.map(&:id),
        source_snapshot_id: source_snapshot&.id,
        source_snapshot: source_snapshot && {
          id: source_snapshot.id,
          source_sha: source_snapshot.source_sha,
          source_ref: source_snapshot.source_ref,
          tree_sha: source_snapshot.tree_sha,
          fingerprint: source_snapshot.fingerprint
        }
      }.compact
    end

    def source_snapshot_details
      return @source_snapshot_details if defined?(@source_snapshot_details)

      sha = merge_train.integration_sha.presence || workflow.artifact("merge_train_integration_sha").presence
      ref = merge_train.integration_branch.presence
      @source_snapshot_details = if sha.present? && ref.present?
        WorkflowSourceSnapshots.record!(
          workflow: workflow,
          creator_step: step,
          source_sha: sha,
          source_ref: "refs/heads/#{ref}",
          tree_sha: sha
        )
      end
    end
  end
end
