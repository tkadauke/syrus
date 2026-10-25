module AttentionReport
  class Report
    DEFAULT_WINDOW_DAYS = 7
    MAX_WINDOW_DAYS = 90
    FEEDBACK_TRIGGER_KINDS = %w[chat_feedback pr_comment].freeze
    HUMAN_JOB_KINDS = %w[issue direct external_pr].freeze
    WASTED_WORKFLOW_TRIGGER_KINDS = %w[retry rebase stack_rebase ci_failure base_refresh_retry].freeze
    LANDING_RECHECK_REASON_KEYS = %w[
      landing_blocker_recheck landing_blocker_wake landing_queue_recheck landing_queue_wake
      recheck_pr_checks wake_landing_queue
    ].freeze

    def initialize(user:, window_days:, now: Time.current)
      @user = user
      @days = [[ Integer(window_days.presence || DEFAULT_WINDOW_DAYS, exception: false) || DEFAULT_WINDOW_DAYS, 1 ].max, MAX_WINDOW_DAYS].min
      @to = now
      @from = @days.days.ago(now)
    end

    def as_json
      {
        window: { days: @days, from: @from.iso8601, to: @to.iso8601 },
        attention: {
          deciding: deciding,
          judging: judging,
          wasted: wasted
        },
        page_time: page_time,
        machine_time: machine_time,
        metadata: {
          attention_totals_exclude_machine_time: true,
          current_user_only: true
        }
      }
    end

    private

    def deciding
      proposal_scope = ChatProposal.joins(:chat_session).where(chat_sessions: { user_id: @user.id })
      proposals = proposal_scope.where(confirmed_at: @from..@to).order(:chat_session_id, :confirmed_at, :id)
      {
        figures: {
          human_created_jobs: figure(Job.where(user_id: @user.id, kind: HUMAN_JOB_KINDS, created_at: @from..@to).count),
          messages_before_confirmed_proposals: figure(messages_before(proposals)),
          proposal_edits: figure(proposal_scope.where(edited_at: @from..@to).count),
          proposal_discards: figure(proposal_scope.where(discarded_at: @from..@to).count)
        },
        estimate: true
      }
    end

    def messages_before(proposals)
      grouped_proposals = proposals.to_a.group_by(&:chat_session_id)
      return 0 if grouped_proposals.empty?

      last_confirmation = grouped_proposals.values.flatten.filter_map(&:confirmed_at).max
      messages = ChatMessage.where(
        chat_session_id: grouped_proposals.keys,
        sender_user_id: @user.id,
        role: "user",
        deleted_at: nil,
        created_at: @from...last_confirmation
      ).order(:chat_session_id, :created_at, :id).group_by(&:chat_session_id)

      grouped_proposals.sum do |session_id, session_proposals|
        prior = @from
        session_messages = Array(messages[session_id])
        cursor = 0
        session_proposals.sum do |proposal|
          cursor += 1 while cursor < session_messages.length && session_messages[cursor].created_at < prior
          count = 0
          while cursor < session_messages.length && session_messages[cursor].created_at < proposal.confirmed_at
            count += 1
            cursor += 1
          end
          prior = proposal.confirmed_at
          count
        end
      end
    end

    def judging
      review_handle_count = if @user.github_handle.present?
        PrReviewComment.where("LOWER(github_handle) = ?", @user.github_handle.downcase)
          .where(comment_created_at: @from..@to).count
      else
        0
      end
      active_review_ms = cleaned_visits.select { |visit| visit.route_id == "job.review" }.sum(&:active_ms)
      {
        figures: {
          job_approvals: figure(JobApproval.where(user_id: @user.id, approved_at: @from..@to).count, estimate: false),
          pr_review_comments: figure(review_handle_count),
          feedback_workflows: figure(Workflow.where(user_id: @user.id, trigger_kind: FEEDBACK_TRIGGER_KINDS, created_at: @from..@to).count),
          active_review_page_time: duration_figure(active_review_ms, cleaned_visits.count { |visit| visit.route_id == "job.review" }, estimate: false)
        },
        estimate: true
      }
    end

    def wasted
      operator_transitions = StateTransition.where(user_id: @user.id, source: "operator", created_at: @from..@to)
      reason_counts = operator_transitions.pluck(:metadata).map { |metadata| metadata.to_h["reason_key"] }.tally
      rechecks = LANDING_RECHECK_REASON_KEYS.sum { |key| reason_counts.fetch(key, 0) }
      overrides = Job.where(
        landing_blocker_override_requested_by_user_id: @user.id,
        landing_blocker_override_requested_at: @from..@to
      )
      rerun_job_ids = human_wasted_workflow_job_ids(operator_transitions)
      recheck_job_ids = job_ids_for_transitions(operator_transitions.select do |transition|
        LANDING_RECHECK_REASON_KEYS.include?(transition.metadata.to_h["reason_key"])
      end)
      reapproval_job_ids = reapproval_after_unchanged_diff_job_ids
      {
        rules: {
          human_retry_rebase_ci_repair_reruns: figure(rerun_job_ids.length, job_ids: rerun_job_ids.uniq),
          landing_blocker_overrides: figure(overrides.count, estimate: false, job_ids: overrides.pluck(:id)),
          landing_blocker_rechecks_and_wakes: figure(rechecks, job_ids: recheck_job_ids),
          reapproval_after_base_change_unchanged_diff: figure(reapproval_job_ids.length, job_ids: reapproval_job_ids.uniq)
        },
        estimate: true
      }
    end

    def human_wasted_workflow_job_ids(operator_transitions)
      direct_workflow_ids = operator_transitions.where(subject_type: "Workflow").pluck(:subject_id)
      job_transitions = operator_transitions.where(subject_type: "Job").group_by(&:subject_id)

      Workflow.where(user_id: @user.id, trigger_kind: WASTED_WORKFLOW_TRIGGER_KINDS, created_at: @from..@to).filter_map do |workflow|
        direct_workflow_ids.include?(workflow.id) || Array(job_transitions[workflow.job_id]).any? do |transition|
          (transition.created_at - workflow.created_at).abs <= 5.seconds
        end ? workflow.job_id : nil
      end
    end

    def job_ids_for_transitions(transitions)
      workflow_job_ids = Workflow.where(id: transitions.filter_map { |item| item.subject_id if item.subject_type == "Workflow" }).pluck(:job_id)
      (workflow_job_ids + transitions.filter_map { |item| item.subject_id if item.subject_type == "Job" }).uniq
    end

    def reapproval_after_unchanged_diff_job_ids
      approval_scope = StateTransition.where(
        user_id: @user.id,
        source: "operator",
        subject_type: "Job",
        event_name: "approve"
      )
      job_ids = approval_scope.where(created_at: @from..@to).distinct.pluck(:subject_id)
      return [] if job_ids.empty?

      approvals = approval_scope.where(subject_id: job_ids, created_at: ..@to)
        .order(:subject_id, :created_at, :id).to_a
      versions = DiffReviewVersion.where(job_id: job_ids, reason: "source_diff", created_at: ..@to)
        .order(:job_id, :created_at, :id).group_by(&:job_id)

      approvals.group_by(&:subject_id).flat_map do |job_id, transitions|
        transitions.each_cons(2).filter_map do |previous, current|
          next false if current.created_at < @from

          previous_version = latest_version_at(versions[job_id], previous.created_at)
          current_version = latest_version_at(versions[job_id], current.created_at)
          job_id if unchanged_diff_after_base_change?(previous_version, current_version)
        end
      end
    end

    def latest_version_at(versions, timestamp)
      Array(versions).reverse_each.find { |version| version.created_at <= timestamp }
    end

    def unchanged_diff_after_base_change?(previous, current)
      return false unless previous && current
      return false if previous.truncated? || current.truncated?
      return false if previous.files_snapshot.blank? || current.files_snapshot.blank?
      return false if previous.base_sha == current.base_sha

      canonical_files(previous.files_snapshot) == canonical_files(current.files_snapshot)
    end

    def canonical_files(files)
      Array(files).map { |file| file.to_h.stringify_keys.sort.to_h }
        .sort_by { |file| [ file["path"].to_s, file["status"].to_s ] }
    end

    def page_time
      return { telemetry_state: "off", by_page_type: {} } unless AppSetting.ui_engagement_telemetry_enabled?

      { telemetry_state: "on", by_page_type: visit_statistics.as_json }
    end

    def machine_time
      runs = Run.where(user_id: @user.id, created_at: @from..@to)
      runtime_ms = runs.where.not(started_at: nil, finished_at: nil).sum do |run|
        [ ((run.finished_at - run.started_at) * 1000).round, 0 ].max
      end
      queue_ms = runs.where.not(started_at: nil).sum do |run|
        [ ((run.started_at - run.created_at) * 1000).round, 0 ].max
      end
      {
        agent_runtime: duration_figure(runtime_ms, runs.where.not(started_at: nil, finished_at: nil).count, estimate: false),
        queue_wait: duration_figure(queue_ms, runs.where.not(started_at: nil).count, estimate: false),
        included_in_attention: false
      }
    end

    def sample_scope
      UiEngagementSample.where(user_id: @user.id, started_at: @from..@to)
    end

    def visit_statistics
      @visit_statistics ||= VisitStatistics.new(sample_scope)
    end

    def cleaned_visits
      @cleaned_visits ||= visit_statistics.cleaned
    end

    def figure(count, estimate: true, job_ids: nil)
      { count: count, sample_count: count, estimate: estimate }.tap do |payload|
        payload[:job_ids] = job_ids if job_ids
      end
    end

    def duration_figure(value_ms, sample_count, estimate:)
      { value_ms: value_ms, sample_count: sample_count, estimate: estimate }
    end
  end
end
