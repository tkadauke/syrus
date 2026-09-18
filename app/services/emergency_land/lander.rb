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
    NOT_CODING_MODE_MESSAGE = "Emergency land is only available for a Job actively linked to a Coding Mode chat.".freeze

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
      return refuse(NOT_CODING_MODE_MESSAGE) unless coding_mode_job?
      return refuse(no_commits_message) unless commits_ahead_of_default_branch?

      pr_number = open_pull_request!
      return refuse(not_mergeable_message(pr_number)) unless mergeable?(pr_number)

      merge = merge!(pr_number)
      return failure("GitHub did not report PR ##{pr_number} as merged.") unless merged?(merge)

      record_audit!(pr_number: pr_number, merge: merge)
      success(pr_number)
    rescue Octokit::Error => e
      failure("GitHub error: #{e.class}: #{e.message}")
    end

    private

    attr_reader :job, :user, :repository

    def coding_mode_job?
      job.coding? && chat_session.present? && chat_session.coding?
    end

    def chat_session
      job.linked_chat
    end

    def commits_ahead_of_default_branch?
      return false if job.branch_name.blank?

      client.compare_commits(repository.slug, repository.default_branch, job.branch_name)[:commits].present?
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

    def mergeable?(pr_number)
      pull_request = client.pull_request(repository.slug, pr_number, bypass_cache: true)
      pull_request.mergeable != false
    end

    def not_mergeable_message(pr_number)
      "GitHub reports PR ##{pr_number} is not mergeable."
    end

    def merge!(pr_number)
      PullRequestMerger.new(repository, client: client).merge(
        pr_number: pr_number,
        commit_title: "Merge #{repository.slug}##{pr_number} via Syrus (emergency land)"
      )
    end

    def merged?(merge)
      merge.respond_to?(:merged) ? merge.merged : merge[:merged]
    end

    def merge_sha(merge)
      merge.respond_to?(:sha) ? merge.sha : merge[:sha]
    end

    def record_audit!(pr_number:, merge:)
      attrs = {
        pr_number: pr_number,
        closure_reason: "emergency_landed",
        emergency_landed_at: Time.current,
        emergency_landed_by_user_id: user.id,
        emergency_landed_by_membership_tier: confirmer_tier
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
