module Api
  module V1
    module App
      class DirectJobsController < BaseController
        include AgentProviderCatalogOptions

        def new
          render json: form_payload
        end

        def create
          repository = find_repository_for_create
          unless repository
            render_error("validation_failed", "Repository not found or not active.", status: :unprocessable_content)
            return
          end

          agent_provider = params[:agent_provider].to_s.presence
          if agent_provider.present? && !Current.user.agent_provider_configured?(agent_provider)
            render_error("validation_failed", "That agent is not configured.", status: :unprocessable_content)
            return
          end
          model = params[:model].to_s.strip.presence
          effort_level = params[:effort_level].to_s.strip.presence

          prompt_text = params[:prompt].to_s.strip
          if prompt_text.blank?
            render_error("validation_failed", "Prompt can't be blank.", status: :unprocessable_content)
            return
          end

          if params[:epic_id].present? && (epic = repository.epics.find_by(id: params[:epic_id])).nil?
            render_error("validation_failed", "Epic not found in that repository.", status: :unprocessable_content)
            return
          end

          if params[:owner_user_id].present?
            owner = User.find_by(id: params[:owner_user_id])
            if owner.nil? || !repository.member_at_least?(owner, "read")
              render_error("validation_failed", "Owner must have repository access.", status: :unprocessable_content)
              return
            end
          end

          planned_execution_attrs = planned_execution_attributes
          job = create_direct_job(repository: repository, agent_provider: agent_provider, model: model, effort_level: effort_level, prompt_text: prompt_text, epic: epic, owner: owner, planned_execution_attrs: planned_execution_attrs)
          unless job
            render_error("validation_failed", @create_direct_job_error || "Job could not be created.", status: :unprocessable_content)
            return
          end
          attachment_errors = attach_initial_job_attachments(job)
          if attachment_errors.any?
            cleanup_failed_direct_job!(job)
            render_error("validation_failed", attachment_errors.to_sentence, status: :unprocessable_content)
            return
          end

          GenerateJobTitleJob.perform_later(job) if job.title_pending?
          job.advance_after_triage! if job.may_advance_after_triage?

          render json: {
            message: "Direct job created.",
            create_more: create_more?,
            redirect_to: direct_job_redirect_path(job),
            job: job_json(job)
          }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        rescue ArgumentError => e
          render_error("validation_failed", e.message, status: :unprocessable_content)
        end

        private

        def form_payload
          repository = selected_repository
          epic = selected_epic(repository)

          {
            repositories: Current.user.repositories.active.order(:owner, :name).map { |repository| repository_json(repository) },
            configured_agent_providers: Current.user.configured_agent_providers.map { |provider| provider_json(provider) },
            provider_routing_options: agent_provider_catalog_options(Current.user),
            selected_repository_id: params[:repository_id].to_s.presence,
            selected_agent_provider: params[:agent_provider].to_s.presence,
            selected_model: params[:model].to_s.presence,
            selected_effort_level: params[:effort_level].to_s.presence,
            selected_epic_id: epic&.id&.to_s,
            epic: epic ? epic_json(epic) : nil,
            create_more: create_more?,
            prompt_templates: PromptTemplate.all.map { |template| prompt_template_json(template) },
            priorities: priority_options,
            accepted_file_content_types: Document::ALLOWED_CONTENT_TYPES,
            new_repository_path: new_repository_path,
            dashboard_jobs_path: dashboard_jobs_path
          }
        end

        def find_repository_for_create
          return Current.user.repositories.active.find_by(id: params[:repository_id]) if params[:repository_id].present?

          slug = params[:repository].presence || params[:repo].presence
          return if slug.blank?

          owner, name = slug.to_s.split("/", 2)
          return if owner.blank? || name.blank?

          Current.user.repositories.active.find_by(owner: owner, name: name)
        end

        def selected_repository
          return nil if params[:repository_id].blank?

          Current.user.repositories.active.find_by(id: params[:repository_id])
        end

        # Scoped to the target repository when one is already selected (the
        # link from an Epic's detail page always carries both), else falls
        # back to any of the user's own epics.
        def selected_epic(repository)
          return nil if params[:epic_id].blank?

          scope = repository ? repository.epics : Current.user.epics
          scope.find_by(id: params[:epic_id])
        end

        def epic_json(epic)
          {
            id: epic.id,
            display_number: epic.slug,
            title: epic.title.to_s
          }
        end

        def create_direct_job(repository:, agent_provider:, model:, effort_level:, prompt_text:, epic: nil, owner: nil, planned_execution_attrs: {})
          title = params[:title].to_s.strip.presence
          priority = params[:priority].to_s.presence
          priority = "medium" unless Job::PRIORITIES.include?(priority)
          target_branch = params[:target_branch].to_s.strip.presence
          delivery_track = params[:delivery_track].to_s.strip.presence
          result = DirectJobs::ProposalCreator.new(user: Current.user).call(
            repository: repository,
            prompt_text: prompt_text,
            title: title,
            priority: priority,
            agent_provider: agent_provider,
            model: agent_provider.present? ? model : nil,
            effort_level: agent_provider.present? ? effort_level : nil,
            epic: epic,
            owner: owner,
            target_branch: target_branch,
            delivery_track: delivery_track,
            planned_execution_attrs: planned_execution_attrs,
            depends_on: Array(params[:depends_on]),
            depends_on_job_ids: Array(params[:depends_on_job_ids]).filter_map { |id| Integer(id, exception: false) },
            dependency_requirements: params[:dependency_requirements] || []
          )
          @create_direct_job_error = result.error
          @create_direct_job_proposal = result.proposal
          @create_direct_job_chat_session = result.chat_session
          @created_direct_job_chat_session = result.created_chat_session
          Metrics::ProductUsage.record(:direct_job_created) if result.success?
          result.job
        end

        def cleanup_failed_direct_job!(job)
          proposal = @create_direct_job_proposal
          chat_session = @create_direct_job_chat_session

          if proposal&.job_id == job.id
            proposal.messages.destroy_all
            chat_session&.chat_attachments&.where(attachable: job)&.destroy_all
            proposal.destroy!
          end

          job.destroy!

          if @created_direct_job_chat_session && chat_session&.system_kind == "direct_job_api" &&
              !chat_session.proposals.exists? && !chat_session.messages.exists?
            chat_session.destroy!
          end
        end

        def planned_execution_attributes
          explicit = PlannedExecutionParams.from_params(params.to_unsafe_h)
          return explicit if explicit.present?

          probe = Current.user.jobs.new(
            repository: selected_repository || Current.user.repositories.active.find_by(id: params[:repository_id]),
            issue_title: params[:title].to_s.strip.presence || GenerateJobTitleJob::PENDING_TITLE,
            issue_body: params[:prompt].to_s.strip
          )
          requirement = PlannedExecutionPlanner.for_job(probe)
          {
            planned_execution_project_label: requirement.project_label,
            planned_execution_target_label: requirement.target_label,
            planned_execution_capabilities: requirement.capabilities,
            planned_execution_source: requirement.source
          }
        end

        def attach_initial_job_attachments(job)
          errors = []

          Array(params.dig(:job_attachment, :files)).compact_blank.each do |file|
            attachment = job.job_attachments.build(attachment_type: "uploaded_file")
            attachment.file.attach(file)
            errors.concat(attachment.errors.full_messages) unless attachment.save
          end

          google_doc_url = params.dig(:job_attachment, :google_doc_url).to_s.strip
          if google_doc_url.present?
            attachment = job.job_attachments.build(
              attachment_type: "google_doc_link",
              google_doc_url: google_doc_url
            )
            errors.concat(attachment.errors.full_messages) unless attachment.save
          end

          errors
        end

        def direct_job_redirect_path(job)
          if create_more?
            new_job_path(repository_id: job.repository_id, create_more: "1")
          else
            job_path(job)
          end
        end

        def repository_json(repository)
          {
            id: repository.id,
            slug: repository.slug,
            repository_path: repository_path(repository),
            default_agent_provider: repository.effective_agent_provider,
            default_agent_provider_label: agent_provider_label(repository.effective_agent_provider)
          }
        end

        def provider_json(provider)
          {
            value: provider,
            label: agent_provider_label(provider),
            models: agent_provider_option_json(provider, user: Current.user)[:models]
          }
        end

        def prompt_template_json(template)
          {
            id: template.id,
            name: template.name,
            description: template.description,
            prompt: template.prompt
          }
        end

        def job_json(job)
          {
            id: job.id,
            title: job.issue_title,
            title_pending: job.title_pending?,
            state: job.state,
            repository: repository_json(job.repository),
            job_path: job_path(job)
          }
        end

        def priority_options
          [
            { value: "urgent", label: "Urgent", description: "Runs before all other priorities" },
            { value: "high", label: "High", description: "Runs before medium and low" },
            { value: "medium", label: "Medium", description: "Default" },
            { value: "low", label: "Low", description: "Yields to higher-priority jobs" }
          ]
        end

        def create_more?
          ActiveModel::Type::Boolean.new.cast(params[:create_more]) == true
        end
      end
    end
  end
end
