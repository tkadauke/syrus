module MainBranchHealth
  # Operator alerts about a broken main branch whose repair is stuck or stopped
  # without progress. Contributed through the plugin's system_alert provider.
  module RepairAlerts
    class << self
      def alerts = [ *no_progress_repairs, *stuck_repairs ]

    def stuck_repairs
      repositories = Syrus::Host::RepositoryRecord.with_broken_main_branch_repair.to_a
      repositories_by_id = repositories.index_by(&:id)
      blocking_jobs = stuck_repair_candidates(repositories_by_id.keys)
        .each_with_object({}) { |job, memo| memo[job.repository_id] ||= job }

      blocking_jobs.filter_map do |repository_id, job|
        repository = repositories_by_id.fetch(repository_id)
        next unless job.state.in?(MainHealthChangedService::NON_PROGRESSING_FIX_JOB_STATES)
        next unless job.updated_at && job.updated_at <= MainHealthChangedService::STUCK_REPAIR_ALERT_AFTER.ago

        sha = repository.last_health_checked_sha.to_s.presence || "unknown"
        sha_short = sha.length > 8 ? sha[0, 8] : sha
        Syrus::Host::SystemAlert.build(
          id: "stuck_main_branch_repair:#{repository.id}:#{job.id}",
          dismissal_key: "stuck_main_branch_repair:#{repository.id}:#{job.id}:#{job.updated_at&.to_i}",
          severity: :alarm,
          title: "Main branch repair is stuck.",
          message: "Main remains broken on <code>#{ERB::Util.html_escape(repository.slug)}</code> at <code>#{ERB::Util.html_escape(sha_short)}</code>, " \
                   "but repair <code>#{ERB::Util.html_escape(job.slug)}</code> has been <code>#{ERB::Util.html_escape(job.state)}</code> since " \
                   "<code>#{ERB::Util.html_escape(job.updated_at&.iso8601)}</code>.",
          action_steps: [
            "Open the stuck-items page to inspect the repair Job and its reconciler evidence.",
            "Retry or force-fail the stuck repair Job so Syrus can spawn a replacement if main is still broken."
          ],
          cta: { text: "Open stuck items", path: "/admin/stuck?refresh=1" }
        )
      end
    end

    def no_progress_repairs
      Syrus::Host::JobRecord
        .includes(:repository, :workflows)
        .where(system_kind: Syrus::Host::JobSystemKindMainBranchRepair, needs_attention_reason: Syrus::Host::GraderLoopProgressNoProgressReason)
        .where(repository_id: Syrus::Host::RepositoryRecord.with_main_branch_repair_enabled.select(:id))
        .where(state: %w[failed closed])
        .order(updated_at: :desc, id: :desc)
        .limit(10)
        .filter_map do |job|
          workflow = job.workflows.to_a
            .sort_by { |candidate| [ candidate.created_at || Time.zone.at(0), candidate.id ] }
            .reverse
            .find { |candidate| candidate.artifact(Syrus::Host::GraderLoopProgressStopArtifactKey).present? }
          stop = workflow&.artifact(Syrus::Host::GraderLoopProgressStopArtifactKey).to_h
          next if stop.blank?

          failing_count = Array(stop["failing_set"]).size
          Syrus::Host::SystemAlert.build(
            id: "no_progress_main_branch_repair:#{job.id}",
            dismissal_key: "no_progress_main_branch_repair:#{job.id}:#{workflow.id}:#{job.updated_at&.to_i}",
            severity: :alarm,
            title: "Main branch repair stopped without progress.",
            message: "Repair <code>#{ERB::Util.html_escape(job.slug)}</code> stopped on " \
                     "<code>#{ERB::Util.html_escape(job.repository.slug)}</code> because the grader failure set did not converge. " \
                     "The latest round still has <code>#{failing_count}</code> failing #{'item'.pluralize(failing_count)}.",
            action_steps: [
              "Open the repair Job and use the grader-loop stop context to split targeted follow-up work.",
              "Do not start another automatic repair from the same branch state; it will repeat the same loop."
            ],
            cta: { text: "Open repair Job", path: "/jobs/#{job.id}" },
            actions: [
              {
                text: "Start planning chat",
                method: "post",
                path: "/api/v1/app/jobs/#{job.id}/start_chat",
                params: { message: no_progress_chat_message(job, workflow, stop) }
              }
            ]
          )
        end
    end

    def no_progress_chat_message(job, workflow, stop)
      failing_set = Array(stop["failing_set"])
      rounds = Array(stop["rounds"])
      lines = [
        "Plan targeted follow-up work for a main-branch repair that stopped without grader progress.",
        "",
        "Repair Job: #{job.slug}",
        "Workflow: #{workflow.slug}",
        "Stop reason: #{stop['explanation'].presence || Syrus::Host::GraderLoopProgressNoProgressReason}",
        "Repository: #{job.repository.slug}",
        "",
        "Failing set:",
        *failing_set.map { |failure| "- #{failure}" },
        "",
        "Rounds:"
      ]
      rounds.each do |round|
        repair = round["repair"].to_h
        lines << "- iteration #{round['iteration']}: #{Array(round['failing_set']).size} failing item(s); " \
          "repair #{repair['kind'].presence || 'none'} diff_bytes=#{repair['diff_bytes'].presence || 0}"
        Array(round["grader_results"]).each do |result|
          lines << "  - #{result['name']}: exit=#{result['exit_code'].presence || 'unknown'} tests=#{Array(result['failed_tests']).size}"
        end
      end
      lines << ""
      lines << "Propose scoped implementation Jobs for the failures above. Do not propose another broad repair retry from the same state."
      lines.join("\n").truncate(8_000)
    end

    def stuck_repair_candidates(repository_ids)
      return Syrus::Host::JobRecord.none if repository_ids.blank?

      Syrus::Host::JobRecord
        .where(repository_id: repository_ids, kind: "direct", state: MainHealthChangedService::BLOCKING_FIX_JOB_STATES)
        .where(
          "jobs.system_kind = :system_kind OR (jobs.system_kind IS NULL AND jobs.issue_title = :title)",
          system_kind: Syrus::Host::JobSystemKindMainBranchRepair,
          title: Syrus::Host::JobMainBranchRepairTitle
        )
        .order(updated_at: :desc, id: :desc)
    end
    end
  end
end
