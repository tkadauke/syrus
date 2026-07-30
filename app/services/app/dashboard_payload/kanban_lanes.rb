module App
  class DashboardPayload
    module KanbanLanes
      extend ActiveSupport::Concern

      # Kanban lane computation extracted from DashboardPayload: building the
      # per-subject lane payloads (jobs/epics/workflows), mapping records into
      # their visible lanes, and resolving the kanban page limit. Mixed back in,
      # so it reads the same @user/@params, the JOB_KANBAN_LANES / WORKFLOW_DONE_STATES
      # / KANBAN_* constants, and the filtered_*_scope + *_json helpers via ancestry.

      def lanes_json
        return [] unless view == "kanban"

        PerformanceLogging.phase("dashboard_kanban_lanes", subject: subject, limit: kanban_limit) do
          case subject
          when "job"
            job_lanes_json
          when "workflow"
            workflow_lanes_json
          else
            epic_lanes_json
          end
        end
      end

      def job_lanes_json
        visible_lanes = user.dashboard_visible_kanban_lanes(:jobs)
        lane_defs = JOB_KANBAN_LANES.select { |lane| visible_lanes.include?(lane.fetch(:key)) }
        records_by_lane = lane_defs.to_h { |lane| [ lane.fetch(:key), [] ] }
        records = PerformanceLogging.phase("dashboard_kanban_jobs.query", lanes: visible_lanes.join(","), limit: kanban_limit) do
          filtered_jobs_scope
            .where(state: job_kanban_candidate_states(visible_lanes))
            .with_latest_workflow_snapshot
            .preload(
              :repository,
              :user,
              :owner_user,
              :claimed_by_user,
              :tags,
              { dependencies: [ :depends_on_epic, { depends_on_job: :repository } ] },
              { chat_proposals: [ :chat_session, :messages ] },
              { epic: { chat_proposals: [ :chat_session, :messages ] } }
            )
            .order(created_at: :desc, id: :desc)
            .limit(kanban_limit)
            .to_a
        end
        PerformanceLogging.phase("dashboard_kanban_jobs.preload_runtime_state", count: records.size) { preload_job_runtime_state(records) }

        preload_epic_job_counts(records)

        records.each do |job|
          lane = job_kanban_lane_for(job, visible_lanes)
          records_by_lane[lane] << job if lane && records_by_lane.key?(lane)
        end

        PerformanceLogging.phase("dashboard_kanban_jobs.serialize", count: records.size) do
          lane_defs.map { |lane| lane_json(lane.fetch(:key), lane.fetch(:title), records_by_lane.fetch(lane.fetch(:key)).map { |job| job_json(job) }) }
        end
      end

      def epic_lanes_json
        lanes = user.dashboard_visible_kanban_lanes(:epics)
        records = PerformanceLogging.phase("dashboard_kanban_epics.query", lanes: lanes.join(","), limit: kanban_limit) do
          filtered_epics_scope
            .includes(:owner, :repository, :owner_user, :jobs)
            .where(state: lanes)
            .order(updated_at: :desc, id: :desc)
            .limit(kanban_limit)
            .to_a
        end
        records_by_lane = lanes.to_h { |lane| [ lane, [] ] }
        records.each { |epic| records_by_lane[epic.state] << epic if records_by_lane.key?(epic.state) }

        PerformanceLogging.phase("dashboard_kanban_epics.serialize", count: records.size) do
          lanes.map { |lane| lane_json(lane, lane.humanize, records_by_lane.fetch(lane).map { |epic| epic_json(epic) }) }
        end
      end

      def workflow_lanes_json
        lanes = user.dashboard_visible_kanban_lanes(:workflows)
        records_by_lane = lanes.to_h { |lane| [ lane, [] ] }
        records = PerformanceLogging.phase("dashboard_kanban_workflows.query", lanes: lanes.join(","), limit: kanban_limit) do
          filtered_workflows_scope
            .where(state: workflow_kanban_candidate_states(lanes))
            .includes(:steps, job: [ :repository, :user, :owner_user ])
            .order(created_at: :desc, id: :desc)
            .limit(kanban_limit)
            .to_a
        end

        records.each do |workflow|
          lane = workflow_kanban_column_for(workflow, lanes)
          records_by_lane[lane] << workflow if lane && records_by_lane.key?(lane)
        end

        PerformanceLogging.phase("dashboard_kanban_workflows.serialize", count: records.size) do
          lanes.map { |lane| lane_json(lane, lane.humanize, records_by_lane.fetch(lane).map { |workflow| workflow_json(workflow) }) }
        end
      end

      def lane_json(key, title, items)
        {
          key: key,
          title: title,
          count: items.size,
          items: items
        }
      end

      def job_kanban_candidate_states(lanes)
        states = []
        states.concat(%w[triaging queued]) if lanes.include?("queued")
        states << "running" if lanes.include?("running")
        states.concat(%w[implemented closed]) if lanes.include?("succeeded")
        states.concat(%w[approved landing]) if lanes.include?("landing")
        states << "failed" if lanes.include?("failed")
        states.concat(%w[triaging blocked_by_epic queued running implemented failed approved landing]) if lanes.include?("blocked")
        states.uniq
      end

      def job_kanban_lane_for(job, visible_lanes)
        candidates = []
        candidates << "landing" if job.approved? || job.landing?
        candidates << "failed" if job.failed? || (job.closed? && !job.dependency_succeeded?)
        candidates << "running" if job.running?
        candidates << "blocked" if job_blocked_for_kanban?(job)
        candidates << "succeeded" if job.implemented? || job.dependency_succeeded?
        candidates << "queued" if job.triaging? || job.queued?
        candidates.find { |lane| visible_lanes.include?(lane) }
      end

      def job_blocked_for_kanban?(job)
        return true if job.blocked_by_epic?
        return false unless job.open?

        job.pr_mergeable == false || job.unsatisfied_dependencies.any?
      end

      def workflow_kanban_candidate_states(lanes)
        states = []
        states << "queued" if lanes.include?("queued")
        states << "running" if lanes.include?("running")
        states.concat(WORKFLOW_DONE_STATES) if lanes.include?("done")
        states << "succeeded" if lanes.include?("succeeded")
        states << "failed" if lanes.include?("failed")
        states.uniq
      end

      def workflow_kanban_column_for(workflow, lanes)
        case workflow.state
        when "queued", "running"
          workflow.state
        when "succeeded"
          lanes.include?("succeeded") ? "succeeded" : "done"
        when "failed"
          lanes.include?("failed") ? "failed" : "done"
        else
          "done" if WORKFLOW_DONE_STATES.include?(workflow.state)
        end
      end

      def kanban_limit
        requested_limit = Integer(params[:kanban_limit], exception: false)
        return requested_limit if KANBAN_LIMIT_OPTIONS.include?(requested_limit)

        KANBAN_PER_PAGE
      end
    end
  end
end
