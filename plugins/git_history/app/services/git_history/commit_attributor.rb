module GitHistory
  # Classifies a single git log entry (as produced by GitHistory::CommitLog)
  # against this repository's Jobs and returns a JSON-ready attribution
  # payload.
  #
  # - "syrus_landed": the sha matches a non-external_pr Job#landed_sha
  #   (set by Steps::AutoMerge / Steps::MergeTrainLand). Attributed to the
  #   creating user, the Job's Epic (if any), and its origin (chat / GitHub
  #   issue / cron).
  # - "external_pr": the sha matches an external_pr-kind Job#landed_sha
  #   (set by PollExternalPrJob when someone else's PR merges). Syrus only
  #   tracked this PR; it did not author it, so it's attributed to the raw
  #   GitHub author/committer, not a Syrus user.
  # - "external_push": no Job at all — a raw commit pushed straight to the
  #   default branch. Attributed to the raw GitHub author/committer.
  class CommitAttributor
    def initialize(repository:, user:)
      @repository = repository
      @user = user
    end

    def attribute(entry)
      job = landed_job_for(entry[:sha])

      base = {
        sha: entry[:sha],
        short_sha: entry[:sha].to_s.first(10),
        subject: entry[:subject],
        authored_at: entry[:authored_at]
      }

      if job && !job.external_pr?
        base.merge(syrus_landed_attributes(job))
      elsif job
        base.merge(external_pr_attributes(entry, job))
      else
        base.merge(external_push_attributes(entry))
      end
    end

    private

    def landed_job_for(sha)
      return nil if sha.blank?

      Job.where(repository_id: @repository.id, landed_sha: sha).first
    end

    def syrus_landed_attributes(job)
      {
        classification: "syrus_landed",
        job: job_payload(job),
        epic: epic_payload(job.epic),
        user: user_payload(job.user),
        origin: origin_payload(job)
      }
    end

    def external_pr_attributes(entry, job)
      {
        classification: "external_pr",
        job: job_payload(job),
        pr_number: job.external_pr_number,
        pr_url: ::App::Presentation.external_pr_url(job),
        author: { name: entry[:author_name], email: entry[:author_email] },
        committer: { name: entry[:committer_name], email: entry[:committer_email] },
        github_author: job.external_pr_author
      }
    end

    def external_push_attributes(entry)
      {
        classification: "external_push",
        author: { name: entry[:author_name], email: entry[:author_email] },
        committer: { name: entry[:committer_name], email: entry[:committer_email] }
      }
    end

    def job_payload(job)
      { id: job.id, slug: job.slug, title: job.title }
    end

    def epic_payload(epic)
      return nil unless epic

      { id: epic.id, slug: epic.slug, title: epic.title }
    end

    def user_payload(user)
      return nil unless user

      { id: user.id, display_name: user.display_name }
    end

    def origin_payload(job)
      if (chat_attachment = chat_attachment_for(job))
        chat_origin_payload(chat_attachment)
      elsif job.scheduled_task_id.present? && job.scheduled_task
        cron_origin_payload(job.scheduled_task)
      elsif job.input_source_id.present?
        issue_origin_payload(job)
      else
        { type: "unknown" }
      end
    end

    def chat_attachment_for(job)
      ChatAttachment
        .where(attachable_type: "Job", attachable_id: job.id)
        .order(:attached_at, :id)
        .first
    end

    # Only include chat_session_id (and title) when the requesting user can
    # actually see that chat — per-Job attribution must never leak the
    # existence, title, or content of a chat the current user has no access
    # to. The commit is still marked as chat-originated either way.
    def chat_origin_payload(chat_attachment)
      chat_session_id = chat_attachment.chat_session_id
      return { type: "chat" } unless @user.accessible_chat_sessions.exists?(id: chat_session_id)

      {
        type: "chat",
        chat_session_id: chat_session_id,
        chat_title: ChatSession.find_by(id: chat_session_id)&.title
      }
    end

    def cron_origin_payload(scheduled_task)
      {
        type: "cron",
        scheduled_task: { id: scheduled_task.id, name: scheduled_task.name }
      }
    end

    def issue_origin_payload(job)
      {
        type: "github_issue",
        issue_number: job.issue_number,
        issue_url: job.issue_number.present? ? "https://github.com/#{@repository.slug}/issues/#{job.issue_number}" : nil
      }
    end
  end
end
