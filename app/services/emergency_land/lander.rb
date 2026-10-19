module EmergencyLand
  # Lands a Coding Mode chat's already-pushed branch immediately, bypassing
  # Syrus's own grader/adversarial-review/visual-review pipeline. Opens the
  # PR the normal way (PullRequestOpener) if one doesn't exist yet for the
  # chat's coding-mode branch, then merges it through GitHub's merge API the
  # same way Steps::AutoMerge does. Never pushes directly to the default
  # branch and never runs a grader or review step -- it only skips Syrus's
  # own gates, not GitHub's (a real merge conflict still refuses).
  #
  # Intentionally has no pending-action/confirmation or MCP-tool wiring of
  # its own -- this is the backend capability an operator-confirmed pending
  # action calls into; that wiring is a separate Job.
  class Lander
    Result = Data.define(:status, :message, :job, :pr_number) do
      def success?
        status == :success
      end

      def refused?
        status == :refused
      end

      def failure?
        status == :failure
      end
    end

    FEATURE_DISABLED_MESSAGE = "Emergency land is not enabled on this instance.".freeze
    PERMISSION_DENIED_MESSAGE = "Emergency land requires repository admin permissions.".freeze
    ELIGIBLE_STATES = %w[queued implemented approved failed coding].freeze
    SKIPPED_CONTROLS = %w[graders adversarial_review visual_review admission_control normal_worker_queue].freeze

    def self.eligible_state?(job) = job.state.in?(ELIGIBLE_STATES)

    def self.land(job:, user:, client: nil)
      new(job: job, user: user, client: client).land
    end

    def initialize(job:, user:, client: nil)
      @job = job
      @user = user
      @repository = job.repository
      @client = client
    end

    def land
      return refuse(FEATURE_DISABLED_MESSAGE) unless Feature.emergency_land_enabled?
      return refuse(PERMISSION_DENIED_MESSAGE) unless Permission.granted?(user: user, repository: repository)
      return refuse("#{job.slug} is not in an emergency-land eligible state (current: #{job.state}).") unless self.class.eligible_state?(job)
      return refuse("#{job.slug} has active runtime work; cancel or finish it before emergency landing.") unless retire_zero_run_handoffs!
      return refuse("#{job.slug} has unsatisfied dependencies.") unless job.dependencies_satisfied?
      return refuse("Branch #{job.branch_name} belongs to more than one open Job; select an unambiguous branch.") if ambiguous_branch?
      return refuse(no_commits_message) unless commits_ahead_of_default_branch?

      pr_number = open_pull_request!
      pull_request = validated_pull_request(pr_number)
      return refuse(not_mergeable_message(pr_number)) unless mergeable?(pull_request)
      expected_sha = pr_head_sha(pull_request)
      return failure("GitHub did not report a head SHA for PR ##{pr_number}.") if expected_sha.blank?

      merge = merge!(pr_number, expected_sha: expected_sha)
      return failure("GitHub did not report PR ##{pr_number} as merged.") unless merged?(merge)

      record_audit!(pr_number: pr_number, merge: merge, source_sha: expected_sha)
      success(pr_number)
    rescue Octokit::Error => e
      failure("GitHub error: #{e.class}: #{e.message}")
    rescue RepositoryContent::Error => e
      failure("Repository content error: #{e.class}: #{e.message}")
    end

    private

    attr_reader :job, :user, :repository

    def retire_zero_run_handoffs!
      return false if job.any_active_run?

      WorkUnits::Ownership.active_units_for_job(job).each do |unit|
        workflow = unit.workflow
        return false if unit.running? || workflow&.runs&.exists?

        if workflow&.queued?
          WorkUnits::WorkflowCancellation.cancel!(workflow, reason: "emergency_land_superseded",
            artifacts: { "cancelled_reason" => "emergency_land_superseded", "cancelled_at" => Time.current.iso8601 })
        end
        unit.preempt!(reason: "emergency_land_superseded") if unit.active?
      end
      true
    end

    def ambiguous_branch?
      return false if job.branch_name.blank?

      repository.jobs.where(branch_name: job.branch_name).where.not(id: job.id).where.not(state: "closed").exists?
    end

    def commits_ahead_of_default_branch?
      return false if job.branch_name.blank?

      content = RepositoryContent.for(repository, user: job.user)
      base = content.resolve(repository.default_branch, max_age: 0)
      head = content.resolve(job.branch_name, max_age: 0)
      content.history(base: base, head: head).commits.present?
    rescue RepositoryContent::UnknownRevision
      false
    end

    def no_commits_message
      branch_label = job.branch_name.presence || "the coding-mode branch"
      "#{branch_label} has no pushed commits ahead of #{repository.default_branch}."
    end

    def open_pull_request!
      return job.pr_number if job.pr_number.present?

      pr_number = PullRequestOpener.new(repository, client: client).open(
        branch: job.branch_name,
        title: job.title,
        body: pr_body,
        job: job
      )
      job.update!(pr_number: pr_number)
      pr_number
    end

    def pr_body
      job.issue_body.presence || "Emergency landed via Syrus."
    end

    def validated_pull_request(pr_number)
      client.pull_request(repository.slug, pr_number, bypass_cache: true)
    end

    def mergeable?(pull_request)
      pull_request.mergeable == true
    end

    def not_mergeable_message(pr_number)
      "GitHub reports PR ##{pr_number} is not mergeable."
    end

    def pr_head_sha(pull_request)
      pull_request&.head&.sha.to_s.presence
    end

    def merge!(pr_number, expected_sha:)
      PullRequestMerger.new(repository, client: client).merge(
        pr_number: pr_number,
        commit_title: "Merge #{repository.slug}##{pr_number} via Syrus (emergency land)",
        expected_sha: expected_sha
      )
    end

    def merged?(merge)
      merge.respond_to?(:merged) ? merge.merged : merge[:merged]
    end

    def merge_sha(merge)
      merge.respond_to?(:sha) ? merge.sha : merge[:sha]
    end

    def record_audit!(pr_number:, merge:, source_sha:)
      attrs = {
        pr_number: pr_number,
        closure_reason: "emergency_landed",
        emergency_landed_at: Time.current,
        emergency_landed_by_user_id: user.id,
        emergency_landed_by_membership_tier: confirmer_tier,
        emergency_land_source_sha: source_sha,
        emergency_land_skipped_controls: SKIPPED_CONTROLS
      }
      sha = merge_sha(merge)
      attrs[:landed_sha] = sha if sha.present?
      job.update!(attrs)
      job.close! if job.may_close?
    end

    # Repository membership tier the confirming user held at confirmation
    # time -- kept alongside closure_reason so the audit trail is queryable
    # without re-deriving permission state from current, possibly-changed
    # RepositoryMembership rows.
    def confirmer_tier
      return "global_admin" if user.admin?

      repository.effective_role_for(user)
    end

    def client
      @client ||= GithubClient.for_authorship(repository: repository, job: job)
    end

    def refuse(message)
      Result.new(status: :refused, message: message, job: job, pr_number: nil)
    end

    def failure(message)
      Result.new(status: :failure, message: message, job: job, pr_number: nil)
    end

    def success(pr_number)
      Result.new(status: :success, message: "Merged PR ##{pr_number} via emergency land.", job: job, pr_number: pr_number)
    end
  end
end
