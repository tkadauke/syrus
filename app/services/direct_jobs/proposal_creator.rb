module DirectJobs
  class ProposalCreator
    Result = Struct.new(:job, :proposal, :chat_session, :created_chat_session, :error, keyword_init: true) do
      def success?
        job.present? && error.blank?
      end
    end

    def initialize(user:)
      @user = user
    end

    def call(repository:, prompt_text:, title:, priority:, agent_provider:, model:, effort_level:, epic: nil, owner: nil, target_branch: nil, delivery_track: nil, planned_execution_attrs: {}, depends_on: [], depends_on_job_ids: [], dependency_requirements: [])
      chat_session, created_chat_session = proposal_chat_session(repository, depends_on | requirement_proposal_slugs(dependency_requirements))
      response = Mcp::Tools::ProposeJobTool.call(
        repo: repository.slug,
        title: proposal_title(title),
        description: prompt_text,
        server_context: { chat_session: chat_session },
        epic_id: epic&.id,
        depends_on: depends_on,
        depends_on_job_ids: depends_on_job_ids,
        dependency_requirements: dependency_requirements,
        provider: agent_provider.presence,
        planned_execution: planned_execution_payload(planned_execution_attrs)
      )
      if response.error?
        cleanup_empty_direct_session!(chat_session) if created_chat_session
        return Result.new(chat_session: chat_session, created_chat_session: created_chat_session, error: response_text(response).delete_prefix("Error: ").strip)
      end

      payload = JSON.parse(response_text(response))
      proposal = ChatProposal.find(payload.fetch("id"))

      filed = ChatProposalFiler.new(
        user: user,
        repository: repository,
        direct_job_options: {
          proposal.id => {
            title_pending: title.blank?,
            priority: priority,
            owner_user: owner,
            model: agent_provider.present? ? model : nil,
            effort_level: agent_provider.present? ? effort_level : nil,
            target_branch: target_branch,
            delivery_track: delivery_track,
            defer_advance: true
          }
        }
      ).file!([ proposal ])
      Result.new(job: filed.jobs.first, proposal: proposal.reload, chat_session: chat_session, created_chat_session: created_chat_session)
    rescue ActiveRecord::RecordInvalid => e
      cleanup_empty_direct_session!(chat_session) if defined?(chat_session) && created_chat_session
      Result.new(chat_session: defined?(chat_session) ? chat_session : nil, created_chat_session: defined?(created_chat_session) ? created_chat_session : false, error: e.record.errors.full_messages.to_sentence)
    rescue ActiveRecord::RecordNotFound, ArgumentError => e
      cleanup_empty_direct_session!(chat_session) if defined?(chat_session) && created_chat_session
      Result.new(chat_session: defined?(chat_session) ? chat_session : nil, created_chat_session: defined?(created_chat_session) ? created_chat_session : false, error: e.message)
    end

    private

    attr_reader :user

    def proposal_chat_session(repository, depends_on)
      slugs = Array(depends_on).map(&:to_s).map(&:strip).reject(&:blank?)
      if slugs.any?
        proposals = ChatProposal.joins(:chat_session).where(chat_sessions: { user_id: user.id }, slug: slugs)
        chat_session_ids = proposals.pluck(:chat_session_id).uniq
        return [ proposals.first.chat_session, false ] if proposals.count == slugs.uniq.length && chat_session_ids.one?
      end

      existing = ChatSession.find_by(user: user, system_kind: "direct_job_api")
      return [ existing, false ] if existing

      [
        ChatSession.create!(
          user: user,
          repository: repository,
          title: "Direct Job API",
          system_kind: "direct_job_api",
          mode: "planning"
        ),
        true
      ]
    end

    def requirement_proposal_slugs(dependency_requirements)
      Array(dependency_requirements).filter_map do |requirement|
        next unless requirement.respond_to?(:to_h)

        source = requirement.to_h
        (source[:proposal_slug] || source["proposal_slug"] || source[:depends_on] || source["depends_on"] || source[:slug] || source["slug"]).to_s.strip.presence
      end
    end

    def proposal_title(title)
      title.presence || GenerateJobTitleJob::PENDING_TITLE
    end

    def planned_execution_payload(attrs)
      {
        project_label: attrs[:planned_execution_project_label],
        target_label: attrs[:planned_execution_target_label],
        capabilities: attrs[:planned_execution_capabilities],
        source: attrs[:planned_execution_source]
      }.compact
    end

    def response_text(response)
      response.content.first.fetch(:text)
    end

    def cleanup_empty_direct_session!(chat_session)
      return unless chat_session&.system_kind == "direct_job_api"
      return if chat_session.proposals.exists? || chat_session.messages.exists?

      chat_session.destroy!
    end
  end
end
