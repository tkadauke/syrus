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
          human_created_jobs: figure(Job.where(owner_user_id: @user.id, kind: HUMAN_JOB_KINDS, created_at: @from..@to).count),
          messages_before_confirmed_proposals: figure(messages_before(proposals)),
          proposal_edits: figure(proposal_scope.where(edited_at: @from..@to).count),
          proposal_discards: figure(proposal_scope.where(discarded_at: @from..@to).count)
        },
        estimate: true
      }
    end

    def messages_before(proposals)
      prior_by_session = {}
      proposals.sum do |proposal|
        lower = prior_by_session[proposal.chat_session_id] || proposal.chat_session.created_at
        prior_by_session[proposal.chat_session_id] = proposal.confirmed_at
        ChatMessage.where(
          chat_session_id: proposal.chat_session_id,
          sender_user_id: @user.id,
          role: "user",
          deleted_at: nil,
          created_at: lower...proposal.confirmed_at
        ).count
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
      ).count
      {
        rules: {
          human_retry_rebase_ci_repair_reruns: figure(human_wasted_workflow_count(operator_transitions)),
          landing_blocker_overrides: figure(overrides, estimate: false),
          landing_blocker_rechecks_and_wakes: figure(rechecks),
          reapproval_after_base_change_unchanged_diff: figure(reapproval_after_rebase_count(operator_transitions))
        },
        estimate: true
      }
    end

    def human_wasted_workflow_count(operator_transitions)
      direct_workflow_ids = operator_transitions.where(subject_type: "Workflow").pluck(:subject_id)
      job_transitions = operator_transitions.where(subject_type: "Job").group_by(&:subject_id)

      Workflow.where(user_id: @user.id, trigger_kind: WASTED_WORKFLOW_TRIGGER_KINDS, created_at: @from..@to).count do |workflow|
        direct_workflow_ids.include?(workflow.id) || Array(job_transitions[workflow.job_id]).any? do |transition|
          (transition.created_at - workflow.created_at).abs <= 5.seconds
        end
      end
    end

    # A rebase rewrites commit identity while preserving the proposed patch.
    # A second operator approval after such a Workflow is therefore attention
    # spent re-approving an unchanged diff, even though the base/head SHAs moved.
    def reapproval_after_rebase_count(operator_transitions)
      approvals = operator_transitions.where(subject_type: "Job", event_name: "approve").order(:created_at, :id)
      approvals.group_by(&:subject_id).sum do |job_id, transitions|
        transitions.each_cons(2).count do |previous, current|
          Workflow.where(job_id: job_id, trigger_kind: %w[rebase stack_rebase], created_at: previous.created_at..current.created_at).exists?
        end
      end
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

    def figure(count, estimate: true)
      { count: count, sample_count: count, estimate: estimate }
    end

    def duration_figure(value_ms, sample_count, estimate:)
      { value_ms: value_ms, sample_count: sample_count, estimate: estimate }
    end
  end
end
