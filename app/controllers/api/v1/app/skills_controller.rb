module Api
  module V1
    module App
      # Powers the skill launch picker: list the skills available to a
      # repository (built-ins plus repo-local `.syrus/skills/*` overrides,
      # each carrying enough provenance to show shadowing before launch)
      # and create a `skill`-kind Job from a chosen skill + submitted args.
      class SkillsController < BaseController
        def index
          repository = find_repository
          render json: skills_index_payload(repository)
        end

        def create
          repository = find_repository

          agent_provider = params[:agent_provider].to_s.presence
          if agent_provider.present? && !Current.user.agent_provider_configured?(agent_provider)
            render_error("validation_failed", "That agent is not configured.", status: :unprocessable_content)
            return
          end

          result = SkillJobs::Creator.call(
            user: Current.user,
            repository: repository,
            name: params[:name].to_s,
            args: plain_json(params[:args].presence || {}),
            agent_provider: agent_provider,
            priority: params[:priority].to_s.presence
          )

          unless result.success?
            render_error("validation_failed", result.error, status: :unprocessable_content)
            return
          end

          render json: {
            message: "Skill job created.",
            redirect_to: job_path(result.job),
            job: job_json(result.job)
          }, status: :created
        end

        private

        def find_repository
          Current.user.repositories.find(params[:repository_id])
        end

        def skills_index_payload(repository)
          resolutions = Skills.all_for(repository: repository, user: Current.user)
          {
            repository: repository_json(repository),
            skills: resolutions.map { |resolution| skill_json(resolution) },
            configured_agent_providers: Current.user.configured_agent_providers.map { |provider| provider_json(provider) },
            priorities: Job::PRIORITIES
          }
        end

        def skill_json(resolution)
          definition = resolution.definition
          {
            name: definition.name,
            description: definition.description,
            source: resolution.source.to_s,
            resolved_path: resolution.path,
            resolved_class: resolution.klass&.name,
            shadows_built_in: resolution.source == :repo_override && Skills::Registry.values.include?(definition.name),
            parameters: definition.parameters.map { |field| field_json(field) }
          }
        end

        def field_json(field)
          {
            key: field.key,
            type: field.type,
            required: field.required,
            label: field.label,
            options: field.options,
            default: field.default,
            depends_on: field.depends_on
          }
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

        def job_json(job)
          {
            id: job.id,
            title: job.issue_title,
            state: job.state,
            skill_name: job.skill_name,
            job_path: job_path(job)
          }
        end

        def agent_provider_label(provider)
          ::App::Presentation.agent_provider_label(provider)
        end
      end
    end
  end
end
