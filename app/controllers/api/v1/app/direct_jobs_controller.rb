module Api
  module V1
    module App
      class DirectJobsController < BaseController
        def new
          render json: form_payload
        end

        def create
          repository = Current.user.repositories.active.find_by(id: params[:repository_id])
          unless repository
            render_error("validation_failed", "Repository not found or not active.", status: :unprocessable_content)
            return
          end

          agent_provider = params[:agent_provider].to_s.presence
          if agent_provider.present? && !Current.user.agent_provider_configured?(agent_provider)
            render_error("validation_failed", "That agent is not configured.", status: :unprocessable_content)
            return
          end

          prompt_text = params[:prompt].to_s.strip
          if prompt_text.blank?
            render_error("validation_failed", "Prompt can't be blank.", status: :unprocessable_content)
            return
          end

          job = create_direct_job(repository: repository, agent_provider: agent_provider, prompt_text: prompt_text)
          attachment_errors = attach_initial_job_attachments(job)
          if attachment_errors.any?
            job.destroy!
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
        end

        private

        def form_payload
          {
            repositories: Current.user.repositories.active.order(:owner, :name).map { |repository| repository_json(repository) },
            configured_agent_providers: Current.user.configured_agent_providers.map { |provider| provider_json(provider) },
            selected_repository_id: params[:repository_id].to_s.presence,
            selected_agent_provider: params[:agent_provider].to_s.presence,
            create_more: create_more?,
            prompt_templates: PromptTemplate.all.map { |template| prompt_template_json(template) },
            priorities: priority_options,
            accepted_file_content_types: Document::ALLOWED_CONTENT_TYPES,
            new_repository_path: new_repository_path,
            dashboard_jobs_path: dashboard_jobs_path
          }
        end

        def create_direct_job(repository:, agent_provider:, prompt_text:)
          selected_agent_provider = agent_provider || repository.effective_agent_provider
          title = params[:title].to_s.strip.presence
          priority = params[:priority].to_s.presence
          priority = "medium" unless Job::PRIORITIES.include?(priority)

          Current.user.jobs.create!(
            repository: repository,
            kind: "direct",
            issue_number: nil,
            issue_title: title || GenerateJobTitleJob::PENDING_TITLE,
            title_pending: title.blank?,
            issue_body: prompt_text,
            agent_provider: selected_agent_provider,
            priority: priority,
            state: Job.initial_state_for_creator(Current.user)
          )
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
            label: agent_provider_label(provider)
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
            { value: "high", label: "High", description: "Runs before medium and low" },
            { value: "medium", label: "Medium", description: "Default" },
            { value: "low", label: "Low", description: "Yields to higher-priority jobs" }
          ]
        end

        def agent_provider_label(provider)
          ::App::Presentation.agent_provider_label(provider)
        end

        def create_more?
          ActiveModel::Type::Boolean.new.cast(params[:create_more]) == true
        end
      end
    end
  end
end
