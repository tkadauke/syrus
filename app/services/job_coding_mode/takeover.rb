module JobCodingMode
  class Takeover
    Error = Class.new(StandardError)

    Result = Data.define(:job, :chat_session, :created_chat)

    def self.call(job:, user:, chat_session: nil)
      new(job: job, user: user, chat_session: chat_session).call
    end

    def initialize(job:, user:, chat_session: nil)
      @job = job
      @user = user
      @chat_session = chat_session
      @created_chat = false
      @claimed_job = false
    end

    def call
      raise Error, "Coding Mode is not enabled on this instance." unless Feature.coding_mode_enabled?
      validate_job!

      ApplicationRecord.transaction do
        @job.lock!
        @chat_session = resolve_chat_session!
        validate_chat_availability!
        validate_job_ownership!
        validate_workflow_ownership!

        if @job.approved?
          Job::ApprovalUnapprover.call(job: @job, user: @user)
          @job.reload
        end

        unless @job.coding?
          raise Error, "#{@job.slug} cannot be claimed for Coding Mode from #{@job.state}." unless @job.may_claim_for_coding?

          @job.linked_chat_id = @chat_session.id
          @job.claim_for_coding!
          @job.save!
          @claimed_job = true
        end
      end

      begin
        ChatWorkspace.ensure_job_branch_checkout!(@chat_session, @job.repository, @job.branch_name)
      rescue StandardError
        @job.release_coding_mode_takeover! if @claimed_job && @job.reload.coding?
        raise
      end
      Result.new(job: @job.reload, chat_session: @chat_session.reload, created_chat: @created_chat)
    end

    private

    def validate_job!
      unless @job.implemented? || @job.approved? || (@job.coding? && @job.linked_chat_id.present?)
        raise Error, "Only implemented or approved Jobs can be opened in Coding Mode."
      end
      raise Error, "Job does not have a branch yet." if @job.branch_name.blank?
    end

    def resolve_chat_session!
      return @chat_session if @chat_session

      if @job.linked_chat_id.present?
        existing = ChatSession.find_by(id: @job.linked_chat_id, user_id: @user.id)
        return existing if existing&.coding?
      end

      @created_chat = true
      title = "Coding: #{@job.title}".first(ChatSession::TITLE_MAX_LENGTH)
      ChatSession.create!(user: @user, mode: "coding", repository: @job.repository, title: title)
    end

    def validate_chat_availability!
      raise Error, "Coding Mode takeover requires a coding chat session." unless @chat_session.coding?

      active_job = Job.where(linked_chat_id: @chat_session.id, state: "coding").where.not(id: @job.id).first
      raise Error, "#{active_job.slug} is already linked to this coding chat." if active_job

      branch = @chat_session.coding_checkout_branch.to_s
      return if branch.blank? || branch == @job.branch_name

      checkout_job = Job.where(repository_id: @job.repository_id, branch_name: branch).where.not(id: @job.id).first
      if checkout_job
        raise Error, "This chat already has an active coding checkout for #{checkout_job.slug}."
      end

      raise Error, "This chat already has an active coding checkout. Cancel it before taking over #{@job.slug}."
    end

    def validate_job_ownership!
      return if @job.linked_chat_id.blank? || @job.linked_chat_id == @chat_session.id

      raise Error, "#{@job.slug} is already linked to a different chat session."
    end

    def validate_workflow_ownership!
      return unless incompatible_active_work?

      raise Error, "#{@job.slug} has active workflow ownership and cannot be opened in Coding Mode yet."
    end

    def incompatible_active_work?
      @job.runs.active.exists? || @job.active_runtime_workflows.any? do |workflow|
        !(workflow.trigger_kind == "initial" && workflow.queued?)
      end
    end
  end
end
