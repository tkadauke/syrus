module App
  class DashboardPayload
    module LandingQueue
      extend ActiveSupport::Concern

      # Landing-queue payloads extracted from DashboardPayload: the queue chrome
      # and rows JSON, the per-request snapshot memoization, and the blocked-reason
      # / position / blocker-entry lookups. Mixed back in via ActiveSupport::Concern,
      # so it reads the same @user/@params and the *_json + scope helpers via ancestry.

      def landing_queue_json
        json = {
          visible: landing_queue_visible?,
          paused: user.landing_paused?,
          toggle_path: "/api/v1/app/dashboard/landing_pause"
        }
        if landing_queue_visible?
          json[:entries] = landing_queue_entries_json
          status = landing_queue_status_json
          json[:status] = status if status.present?
        end
        json
      end

      def landing_queue_chrome_json
        {
          visible: landing_queue_visible?,
          paused: user.landing_paused?,
          toggle_path: "/api/v1/app/dashboard/landing_pause"
        }
      end

      def landing_queue_visible?
        subject == "job" && active_smart_folder&.attention_preset == "landing_queue"
      end

      def blocked_folder_visible?
        subject == "job" && active_smart_folder&.attention_preset == "blocked"
      end

      def ensure_landing_queue_snapshot!
        return if @landing_queue_snapshot_checked

        @landing_queue_snapshot_checked = true
        candidates = jobs_base_scope.where(state: %w[ approved landing ])
        return unless candidates.where(landing_queue_cached_at: nil).exists?

        LandingQueueProcessorJob.perform_later
      end

      def landing_queue_position_for(job)
        job.landing_queue_position if landing_queue_visible?
      end

      def landing_queue_blocked_reason_for(job)
        return unless landing_queue_visible?

        reason = job.landing_queue_blocked_reason.presence
        return nil if normal_landing_queue_wait_reason?(reason)

        reason || merge_train_start_blocked_reason_text_for(job) || landing_state_drift_reason_for(job)
      end

      def landing_queue_wait_reason_for(job)
        return unless landing_queue_visible?

        reason = job.landing_queue_blocked_reason.presence
        return reason if normal_landing_queue_wait_reason?(reason)
        return nil if merge_train_start_blocked_reason_for(job)

        merge_train_wait_reason_for(job)
      end

      def blocked_reason_for(job)
        return unless blocked_folder_visible?

        if job.landing_queue_blocked_reason.present? && !normal_landing_queue_wait_reason?(job.landing_queue_blocked_reason)
          return job.landing_queue_blocked_reason
        end
        return { key: "pr_not_mergeable" } if job.pr_mergeable == false

        dep = preloaded_blocked_deps_by_job_id[job.id]
        return unless dep

        if dep.depends_on_epic_id.present?
          { key: "waiting_epic_to_complete", params: { number: dep.depends_on_epic&.number } }
        elsif dep.depends_on_job_id.present?
          { key: "waiting_to_merge", params: { slug: dep.depends_on_job.slug } }
        else
          slug = dep.unresolved_slug
          { key: "waiting_to_merge", params: { slug: slug } } if slug.present?
        end
      end

      def preloaded_blocked_deps_by_job_id
        return {} unless blocked_folder_visible?

        @preloaded_blocked_deps_by_job_id ||= load_blocked_deps_by_job_id
      end

      def load_blocked_deps_by_job_id
        job_ids = (@current_jobs || []).map(&:id)
        return {} if job_ids.empty?

        JobDependency
          .where(job_id: job_ids)
          .includes(:depends_on_job, :depends_on_epic, :unresolved_chat_proposal)
          .order(:id)
          .reject { |dep| dep.depends_on_job&.dependency_succeeded? || dep.depends_on_epic&.done? }
          .each_with_object({}) { |dep, hash| hash[dep.job_id] ||= dep }
      end

      def landing_queue_entry_key_for(job)
        if landing_queue_visible?
          job.landing_queue_entry_key.presence || "job:#{job.id}"
        end
      end

      NORMAL_LANDING_QUEUE_WAIT_REASON_KEYS = %w[ waiting_epic_merge_train waiting_epicless_bundle ].freeze

      def normal_landing_queue_wait_reason?(reason)
        return false unless reason.respond_to?(:to_h)

        hash = reason.to_h
        NORMAL_LANDING_QUEUE_WAIT_REASON_KEYS.include?((hash["key"] || hash[:key]).to_s)
      end

      def merge_train_start_blocked_reason_text_for(job)
        reason = merge_train_start_blocked_reason_for(job)
        "Merge train queued: #{display_start_blocked_reason(reason)}" if reason
      end

      def merge_train_wait_reason_for(job)
        return unless AppSetting.merge_train_enabled?
        return unless job.epic_id.present?

        return "Merge train already active" if merge_train_active_for?(job)

        dispatcher_blocker = merge_train_dispatcher_blocker_for(job)
        "Merge train queued: #{dispatcher_blocker}" if dispatcher_blocker.present?
      end

      def landing_state_drift_reason_for(job)
        return unless job.landing?
        return if active_workflow_for_landing_queue_job?(job)

        "Landing state drift: no active workflow"
      end

      def landing_queue_status_json
        jobs = current_landing_queue_jobs
        return nil if jobs.empty?

        front_jobs = landing_queue_front_jobs(jobs)
        return landing_queue_paused_status(front_jobs) if user.landing_paused?

        inconsistent = landing_queue_inconsistent_active_attempt(front_jobs)
        return inconsistent if inconsistent

        blocked_unit = landing_queue_blocked_work_unit(front_jobs)
        return landing_queue_blocked_work_unit_status(blocked_unit, front_jobs) if blocked_unit

        active_unit = landing_queue_active_work_unit(front_jobs)
        return nil if active_unit&.workflow && Workflow::TriggerKind::ACTIVE_STATES.include?(active_unit.workflow.state)

        failed_workflow = landing_queue_recent_failed_workflow(front_jobs)
        return landing_queue_failed_workflow_status(failed_workflow, front_jobs) if failed_workflow

        return nil if active_landing_work_for_visible_queue?

        drift_job = front_jobs.find { |job| landing_state_drift_reason_for(job).present? }
        return landing_queue_drift_status(drift_job) if drift_job

        first_job = front_jobs.first
        if first_job && landing_queue_front_entry_position(front_jobs).present? && !active_unit
          return landing_queue_idle_status(first_job)
        end

        nil
      end

      def merge_train_start_blocked_reason_for(job)
        merge_train_workflow_data_by_epic_id.dig(job.epic_id, :start_blocked_reason)
      end

      def merge_train_active_for?(job)
        merge_train_workflow_data_by_epic_id.dig(job.epic_id, :active) || active_merge_train_ids_by_epic_id.key?(job.epic_id)
      end

      def merge_train_dispatcher_blocker_for(job)
        merge_train_dispatcher_blockers_by_epic_id[job.epic_id]
      end

      def active_workflow_for_landing_queue_job?(job)
        active_workflow_job_ids.include?(job.id) || merge_train_active_for?(job)
      end

      def display_start_blocked_reason(reason)
        reason.to_s.tr("_", " ")
      end

      def merge_train_workflow_data_by_epic_id
        @merge_train_workflow_data_by_epic_id ||= begin
          epic_ids = landing_queue_epic_ids
          if epic_ids.empty?
            {}
          else
            merge_train_work_unit_data_by_epic_id(epic_ids)
          end
        end
      end

      def merge_train_work_unit_data_by_epic_id(epic_ids)
        active_merge_train_work_units_by_epic_id(epic_ids)
          .values
          .flatten
          .uniq(&:id)
          .sort_by { |unit| [ unit.created_at || Time.at(0), unit.id || 0 ] }
          .reverse
          .each_with_object({}) do |unit, map|
            epic_ids_for_unit(unit, allowed_epic_ids: epic_ids).each do |epic_id|
              data = (map[epic_id] ||= {})
              data[:active] = true
              data[:start_blocked_reason] ||= unit.blocked_reason if unit.blocked?
              data[:start_blocked_reason] ||= WorkUnits::StartBlock.for(unit.workflow).reason if unit.workflow&.queued?
            end
          end
      end

      def active_merge_train_work_units_by_epic_id(epic_ids)
        allowed_ids = Array(epic_ids).map(&:to_i).select(&:positive?)
        return {} if allowed_ids.empty?

        epic_scoped_ids = WorkUnit
          .where(kind: WorkDefinitions.for("merge_train").kind, scope_type: "epic", scope_id: allowed_ids, state: WorkUnits::Ownership::ACTIVE_STATES)
          .select(:id)
        member_scoped_ids = WorkUnit
          .joins(work_unit_members: :job)
          .where(kind: WorkDefinitions.for("merge_train").kind, state: WorkUnits::Ownership::ACTIVE_STATES, jobs: { epic_id: allowed_ids })
          .select(:id)

        WorkUnit
          .where(id: epic_scoped_ids)
          .or(WorkUnit.where(id: member_scoped_ids))
          .includes(:workflow, work_unit_members: :job)
          .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |unit, map|
            epic_ids_for_unit(unit, allowed_epic_ids: allowed_ids).each { |epic_id| map[epic_id] << unit }
          end
      end

      def epic_ids_for_unit(unit, allowed_epic_ids:)
        ids = []
        ids << unit.scope_id if unit.scope_type == "epic"
        ids.concat(unit.work_unit_members.map { |member| member.job&.epic_id })
        ids.compact.map(&:to_i).select { |epic_id| allowed_epic_ids.include?(epic_id) }.uniq
      end

      def active_merge_train_ids_by_epic_id
        @active_merge_train_ids_by_epic_id ||= begin
          epic_ids = landing_queue_epic_ids
          epic_ids.empty? ? {} : MergeTrain.active.where(epic_id: epic_ids).pluck(:epic_id, :id).to_h
        end
      end

      def merge_train_dispatcher_blockers_by_epic_id
        @merge_train_dispatcher_blockers_by_epic_id ||= begin
          epic_ids = landing_queue_epic_ids
          epics = epic_ids.empty? ? [] : Epic.where(id: epic_ids).includes(:repository)
          epics.each_with_object({}) do |epic, map|
            reason = MergeTrainDispatcher.blocker_reason(epic)
            map[epic.id] = reason if reason.present?
          end
        end
      end

      def active_workflow_job_ids
        @active_workflow_job_ids ||= begin
          job_ids = current_landing_queue_jobs.map(&:id)
          WorkUnits::Ownership.active_job_ids(job_ids)
        end
      end

      def active_landing_work_for_visible_queue?
        repository_ids = current_landing_queue_jobs.filter_map(&:repository_id).uniq
        return false if repository_ids.empty?

        WorkUnit
          .joins(:workflow)
          .where(repository_id: repository_ids, kind: WorkDefinitions.landing_lock_kinds, state: WorkUnits::Ownership::ACTIVE_STATES)
          .where(workflows: { state: Workflow::TriggerKind::ACTIVE_STATES })
          .exists?
      end

      def landing_queue_front_jobs(jobs)
        positioned = jobs.select { |job| job.landing_queue_entry_position.present? }
        sorted = (positioned.presence || jobs).sort_by { |job| [ job.landing_queue_entry_position || Float::INFINITY, job.approved_at || job.created_at || Time.at(0), job.id ] }
        first = sorted.first
        return [] unless first

        key = first.landing_queue_entry_key.presence || "job:#{first.id}"
        sorted.select { |job| (job.landing_queue_entry_key.presence || "job:#{job.id}") == key }
      end

      def landing_queue_front_entry_position(jobs)
        jobs.filter_map(&:landing_queue_entry_position).min
      end

      def landing_queue_active_work_unit(jobs)
        landing_queue_active_work_units(jobs).find { |unit| unit.running? || unit.queued? } ||
          landing_queue_active_work_units(jobs).first
      end

      def landing_queue_blocked_work_unit(jobs)
        landing_queue_active_work_units(jobs).find(&:blocked?)
      end

      def landing_queue_active_work_units(jobs)
        ids = Array(jobs).map(&:id)
        return [] if ids.empty?

        @landing_queue_active_work_units_by_job_ids ||= {}
        cache_key = ids.sort.join(",")
        @landing_queue_active_work_units_by_job_ids[cache_key] ||= WorkUnitMember
          .joins(:work_unit)
          .where(job_id: ids, work_units: { state: WorkUnits::Ownership::ACTIVE_STATES, kind: WorkDefinitions.landing_lock_kinds })
          .includes(work_unit: :workflow)
          .order(WorkUnits::Ownership.active_priority_order)
          .map(&:work_unit)
          .uniq
      end

      def landing_queue_inconsistent_active_attempt(jobs)
        unit = landing_queue_active_work_units(jobs).find { |candidate| candidate.workflow&.failed? || candidate.workflow&.cancelled? }
        return unless unit&.workflow

        workflow = unit.workflow
        {
          tone: "danger",
          title: "Landing queue is wedged on #{landing_queue_unit_label(jobs)}.",
          summary: "#{workflow.slug} is #{workflow.state}, but #{unit_label(unit)} is still #{unit.state}. The reconciler should clean this up; retry or cancel the landing attempt if it does not.",
          links: landing_queue_status_links(jobs, workflow)
        }
      end

      def landing_queue_recent_failed_workflow(jobs)
        ids = Array(jobs).map(&:id)
        return if ids.empty?

        Workflow
          .where(job_id: ids, trigger_kind: WorkDefinitions.landing_workflow_kinds, state: %w[ failed cancelled ])
          .order(created_at: :desc, id: :desc)
          .includes(:job)
          .first
      end

      def landing_queue_paused_status(jobs)
        {
          tone: "warning",
          title: "Landing queue is paused.",
          summary: "#{landing_queue_unit_label(jobs)} is waiting because the landing queue is manually paused.",
          links: landing_queue_status_links(jobs)
        }
      end

      def landing_queue_blocked_work_unit_status(unit, jobs)
        reason = display_start_blocked_reason(unit.blocked_reason.presence || "blocked")
        summary = "#{unit_label(unit)} is blocked by #{reason}."
        summary += " It will be checked again at #{unit.blocked_until.iso8601}." if unit.blocked_until.present?
        {
          tone: "warning",
          title: "Landing queue is waiting on #{landing_queue_unit_label(jobs)}.",
          summary: summary,
          links: landing_queue_status_links(jobs, unit.workflow)
        }
      end

      def landing_queue_failed_workflow_status(workflow, jobs)
        failed_step = workflow.steps.where(state: "failed").order(:position).first
        detail = failed_step ? "#{failed_step_label(failed_step)} failed" : "the workflow failed without a failed Step"

        {
          tone: "danger",
          title: "Landing queue is stopped on #{landing_queue_unit_label(jobs)}.",
          summary: "#{workflow.slug} #{workflow.state}: #{detail}. Retry the failed step or retry landing after reviewing the workflow output.",
          links: landing_queue_status_links(jobs, workflow)
        }
      end

      def landing_queue_drift_status(job)
        {
          tone: "danger",
          title: "Landing queue state drift detected.",
          summary: "#{job.slug} is marked landing, but no active landing workflow owns it. The reconciler should return it to the queue; retry landing if it remains stuck.",
          links: landing_queue_status_links([ job ])
        }
      end

      def landing_queue_idle_status(job)
        {
          tone: "warning",
          title: "Landing queue is waiting to dispatch.",
          summary: "#{job.slug} is first in line, but there is no active landing workflow yet. The landing processor or reconciler should pick it up shortly.",
          links: landing_queue_status_links([ job ])
        }
      end

      def landing_queue_status_links(jobs, workflow = nil)
        primary_job = workflow&.job || jobs.first
        links = []
        links << { label: primary_job.slug, path: "/jobs/#{primary_job.id}" } if primary_job
        links << { label: workflow.slug, path: "/jobs/#{workflow.job_id}?tab=workflows#workflow-#{workflow.id}" } if workflow
        links
      end

      def landing_queue_unit_label(jobs)
        jobs = Array(jobs)
        return "the first landing unit" if jobs.empty?
        return jobs.first.slug if jobs.one?

        "#{jobs.first.slug} and #{jobs.size - 1} more"
      end

      def unit_label(unit)
        "WU-#{unit.id}"
      end

      def failed_step_label(step)
        Step::Kind.label_for(step.kind)
      rescue ArgumentError
        step.kind.to_s.tr("_", " ")
      end

      def landing_queue_epic_ids
        @landing_queue_epic_ids ||= current_landing_queue_jobs.filter_map(&:epic_id).uniq
      end

      def landing_queue_entries
        return [] unless landing_queue_visible?

        @landing_queue_entries ||= current_landing_queue_jobs.group_by { |job| job.landing_queue_entry_key.presence || "job:#{job.id}" }
      end

      def landing_queue_entries_json
        blocker_jobs_by_id = landing_queue_blocker_jobs_by_id
        bundle_job_counts = landing_queue_bundle_job_counts(blocker_jobs_by_id.values)

        landing_queue_entries.map do |key, jobs|
          blocker_ids = jobs.flat_map { |job| Array(job.landing_queue_blocker_job_ids) }.uniq
          {
            key: key,
            position: jobs.filter_map(&:landing_queue_entry_position).min,
            job_ids: jobs.map(&:id),
            blocker_jobs: blocker_ids.filter_map { |id| blocker_jobs_by_id[id] }.map { |job| landing_queue_blocker_job_json(job, key, bundle_job_counts) },
            dependency_edges: jobs.flat_map { |job| Array(job.landing_queue_dependency_edges) }.uniq
          }
        end
      end

      # Blocker jobs are loaded outside the paginated current-page scope, so a
      # blocker's own bundle size can't be read off `landing_queue_entries`
      # (which only covers jobs on the current page). `landing_queue_entry_key`
      # is cached directly on the Job row by LandingQueueProcessor, so one
      # grouped count query gives every blocker's bundle size without N+1s.
      def landing_queue_bundle_job_counts(jobs)
        keys = jobs.filter_map { |job| job.landing_queue_entry_key if job.landing_queue_entry_key.to_s.start_with?("job_bundle:") }.uniq
        return {} if keys.empty?

        Job.where(landing_queue_entry_key: keys).group(:landing_queue_entry_key).count
      end

      def current_landing_queue_jobs
        current_result if @current_jobs.nil?
        @current_jobs || []
      end

      def landing_queue_blocker_jobs_by_id
        ids = current_landing_queue_jobs.flat_map { |job| Array(job.landing_queue_blocker_job_ids) }.uniq
        return {} if ids.empty?

        Job.where(id: ids).with_latest_workflow_snapshot.includes(:epic, :repository).index_by(&:id)
      end

      def landing_queue_blocker_job_json(job, entry_key, bundle_job_counts = {})
        json = {
          id: job.id,
          title: job.issue_title.presence || job.slug,
          job_path: "/jobs/#{job.id}",
          state: job.state,
          pr_number: job.pr_number || job.external_pr_number,
          pr_is_external: App::Presentation.pr_external?(job),
          pr_path: App::Presentation.job_pr_url(job) || App::Presentation.external_pr_url(job),
          repository: repository_json(job.repository),
          latest_workflow_state: App::Presentation.workflow_dashboard_state(job.latest_workflow_state, job.latest_workflow_trigger_kind),
          latest_workflow_trigger_kind: job.latest_workflow_trigger_kind,
          latest_workflow_id: job.latest_workflow_id,
          started_at: job.started_at&.iso8601,
          created_at: job.created_at&.iso8601
        }
        if job.landing_queue_entry_key.to_s.start_with?("job_bundle:") && job.landing_queue_entry_key != entry_key
          json[:bundle_other_job_count] = (bundle_job_counts[job.landing_queue_entry_key] || 1) - 1
        elsif job.epic_id != landing_queue_entry_epic_id(entry_key)
          json[:epic_id] = job.epic_id
          json[:epic_title] = job.epic&.title
        end
        json
      end

      def landing_queue_entry_epic_id(entry_key)
        match = entry_key.to_s.match(/\Aepic:(\d+)\z/)
        match ? match[1].to_i : nil
      end
    end
  end
end
