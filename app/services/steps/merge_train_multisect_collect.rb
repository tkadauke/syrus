module Steps
  class MergeTrainMultisectCollect < Base
    include MergeTrainStep

    def call
      case phase
      when "oracle"
        collect_oracle!
      when "round"
        collect_round!
      when "omitted_confirmation"
        collect_omitted_confirmation!
      else
        abort!("unknown_phase")
      end
    end

    private

    def details = step.details.to_h
    def phase = details["phase"].to_s
    def round = details["round"].to_i

    def collect_oracle!
      result = dependency_results.first
      return abort!("oracle_did_not_reproduce", "oracle" => result) unless result&.dig("reproduced") == true

      schedule_round!(merge_train.members.includes(:job).order(:position).to_a, round: 1)
    end

    def collect_round!
      results = dependency_results
      reproducing = results.select { |result| result["reproduced"] == true }
      return abort!("multiple_sections_reproduced", "round" => round, "sections" => results) if reproducing.size > 1

      omitted_ids = Array(details["omitted_member_ids"]).map(&:to_i)
      return abort!("no_subset_reproduced", "round" => round, "sections" => results) if reproducing.empty? && omitted_ids.empty?

      if reproducing.one? && omitted_ids.any?
        omitted = members_by_ids(omitted_ids)
        MergeTrainMultisectWorkflow.append_collect_with_evaluations!(
          after_step: step,
          collect_details: {
            phase: "omitted_confirmation",
            round: round,
            reproducing_member_ids: Array(reproducing.first["members"]).map { |member| member["merge_train_member_id"] },
            reproducing_section: reproducing.first
          },
          evaluations: [ evaluation_details(members: omitted, role: "omitted_confirmation", round: round, section_index: details["omitted_section_index"]) ]
        )
      else
        next_ids = reproducing.one? ? Array(reproducing.first["members"]).map { |member| member["merge_train_member_id"] } : omitted_ids
        narrow_or_attribute!(members_by_ids(next_ids))
      end
    end

    def collect_omitted_confirmation!
      result = dependency_results.first
      return abort!("multiple_sections_reproduced", "round" => round, "omitted_confirmation" => result, "reproducing_section" => details["reproducing_section"]) if result&.dig("reproduced") == true

      narrow_or_attribute!(members_by_ids(Array(details["reproducing_member_ids"]).map(&:to_i)))
    end

    def narrow_or_attribute!(candidates)
      return abort!("no_subset_reproduced", "round" => round) if candidates.empty?
      return attribute!(candidates.first) if candidates.one?

      schedule_round!(candidates, round: round + 1)
    end

    def schedule_round!(candidates, round:)
      width = MergeTrainMultisect.section_width_for(repository)
      sections = MergeTrainMultisect.partition(candidates, section_width: width)
      graded = sections[0...-1]
      omitted = sections.last || []
      MergeTrainMultisectWorkflow.append_collect_with_evaluations!(
        after_step: step,
        collect_details: {
          phase: "round",
          round: round,
          candidate_member_ids: candidates.map(&:id),
          omitted_member_ids: omitted.map(&:id),
          omitted_section_index: sections.size - 1
        },
        evaluations: graded.each_with_index.map do |section, index|
          evaluation_details(members: section, role: "section", round: round, section_index: index)
        end
      )
      append_round_artifact!(round: round, candidates: candidates, sections: sections)
      log("[merge_train_multisect_collect] scheduled round #{round}: #{graded.size} focused section evaluation(s)")
    end

    def attribute!(member)
      payload = base_payload("attributed").merge(
        "reason" => "isolated_member",
        "attributed_member" => MergeTrainMultisect.member_payload(member),
        "recorded_at" => Time.current.iso8601
      )
      workflow.set_artifact!(MergeTrainMultisect::ARTIFACT_KEY, payload)
      workflow.set_artifact!(MergeTrainMultisectWorkflow::COMPLETED_ARTIFACT_KEY, payload)
      log("[merge_train_multisect_collect] attributed train failure to #{member.job.slug}")
      fail_with!(:grader_failure, "merge_train_multisect: isolated #{member.job.slug}", evidence: { attributed_job_id: member.job_id })
    end

    def abort!(reason, extra = {})
      payload = base_payload("aborted").merge(extra).merge(
        "reason" => reason,
        "recorded_at" => Time.current.iso8601
      )
      workflow.set_artifact!(MergeTrainMultisect::ARTIFACT_KEY, payload)
      workflow.set_artifact!(MergeTrainMultisectWorkflow::COMPLETED_ARTIFACT_KEY, payload)
      log("[merge_train_multisect_collect] aborted: #{reason}")
      fail_with!(:grader_failure, "merge_train_multisect: #{reason}", evidence: { reason: reason })
    end

    def base_payload(status)
      current = workflow.artifact(MergeTrainMultisect::ARTIFACT_KEY).to_h
      current.merge(
        "status" => status,
        "section_width" => MergeTrainMultisect.section_width_for(repository),
        "members" => MergeTrainMultisect.members_payload(merge_train.members.includes(:job).order(:position)),
        "failing_set" => MergeTrainMultisect.focused_selector(workflow),
        "rounds" => Array(current["rounds"])
      )
    end

    def append_round_artifact!(round:, candidates:, sections:)
      current = workflow.artifact(MergeTrainMultisect::ARTIFACT_KEY).to_h
      rounds = Array(current["rounds"]).reject { |entry| entry["round"].to_i == round }
      rounds << {
        "round" => round,
        "candidate_member_ids" => candidates.map(&:job_id),
        "sections" => sections.each_with_index.map do |section, index|
          {
            "index" => index,
            "omitted" => index == sections.size - 1,
            "members" => MergeTrainMultisect.members_payload(section)
          }
        end
      }
      workflow.set_artifact!(MergeTrainMultisect::ARTIFACT_KEY, current.merge("rounds" => rounds))
    end

    def evaluation_details(members:, role:, round:, section_index:)
      snapshot = workflow.source_snapshots.published.newest_first.first
      {
        role: role,
        round: round,
        section_index: section_index,
        member_ids: members.map(&:id),
        source_snapshot_id: snapshot&.id,
        source_snapshot: snapshot && {
          id: snapshot.id,
          source_sha: snapshot.source_sha,
          source_ref: snapshot.source_ref,
          tree_sha: snapshot.tree_sha,
          fingerprint: snapshot.fingerprint
        }
      }.compact
    end

    def dependency_results
      workflow.steps.where(id: step.depends_on_step_ids).order(:position).map { |dependency| dependency.details.to_h["result"] }.compact
    end

    def members_by_ids(ids)
      merge_train.members.includes(:job).where(id: ids).order(:position).to_a
    end
  end
end
