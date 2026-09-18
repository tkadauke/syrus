require "stringio"

module DirectJobs
  # Shared boilerplate behind every "create a direct Job right now, with a
  # prompt we already have in hand" shortcut: BugReports::Creator (in-app
  # bug reports) and SyrusDev::ToolCardJobCreator (the Tool Card Catalog's
  # "Create Job" button) both create a Job, push it straight through
  # triage, attach at most a couple of files, and kick off async title
  # generation when the title is left blank. Extracted here so a future
  # change to attachment columns or triage semantics has one place to
  # update instead of two copies drifting apart.
  #
  # Not used by the main "New Job" form
  # (Api::V1::App::DirectJobsController#create_direct_job), which supports
  # an explicit always-present title, an owner-selectable needs_triage gate
  # via Job.initial_state_for_creator, epic/owner assignment, and multiple
  # attachment kinds (uploaded files + Google Doc links) that this narrower
  # "quick create" helper doesn't need to model.
  class Creator
    Result = Struct.new(:job, :error, keyword_init: true) do
      def success?
        job.present? && error.blank?
      end
    end

    # body is the raw (already-decoded) file content; attach! wraps it in a
    # fresh StringIO so callers never have to think about IO position.
    Attachment = Struct.new(:source_url, :filename, :content_type, :body, keyword_init: true)

    def initialize(user:)
      @user = user
    end

    def call(repository:, prompt_text:, title: nil, priority: "medium", attachments: [])
      job = nil

      ActiveRecord::Base.transaction do
        job = user.jobs.create!(
          repository: repository,
          kind: "direct",
          issue_number: nil,
          issue_title: title.presence || GenerateJobTitleJob::PENDING_TITLE,
          title_pending: title.blank?,
          issue_body: prompt_text,
          agent_provider: repository.effective_agent_provider,
          priority: priority
        )

        job.advance_after_triage! if job.may_advance_after_triage?

        Array(attachments).each { |attachment| attach!(job, attachment) }
      end

      GenerateJobTitleJob.perform_later(job) if job.title_pending?

      Result.new(job: job)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(error: e.record.errors.full_messages.to_sentence)
    end

    private

    attr_reader :user

    def attach!(job, attachment)
      document = job.job_attachments.build(
        source_url: attachment.source_url,
        filename: attachment.filename,
        content_type: attachment.content_type,
        byte_size: attachment.body.bytesize
      )
      document.file.attach(
        io: StringIO.new(attachment.body),
        filename: attachment.filename,
        content_type: attachment.content_type,
        identify: false
      )
      document.save!
    end
  end
end
