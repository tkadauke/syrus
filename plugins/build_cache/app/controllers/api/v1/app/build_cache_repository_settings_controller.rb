module Api
  module V1
    module App
      # Per-repository opt-in for sccache SCCACHE_BASEDIRS path normalization
      # (see BuildCache::RepositorySettings, config/syrus_docs/sccache_build_cache.md's
      # "Cache-safe coverage recipe"). Deliberately narrow: the only setting
      # here is `basedirs_safe`, gated behind a repository the current user
      # can actually see, same access-scoping pattern as
      # InsightScheduleConfigsController.
      class BuildCacheRepositorySettingsController < BaseController
        def show
          repository = find_repository
          return unless repository

          render json: settings_json(BuildCache::RepositorySettings.for_repository(repository))
        end

        def update
          repository = find_repository
          return unless repository

          settings = BuildCache::RepositorySettings.for_repository(repository) ||
            BuildCache::RepositorySettings.new(repository: repository)
          settings.assign_attributes(settings_params)

          if settings.save
            render json: settings_json(settings)
          else
            render_error("validation_failed", settings.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        private

        def find_repository
          repo = Current.user.repositories.find_by(id: params[:id])
          render_error("not_found", "Repository not found.", status: :not_found) unless repo
          repo
        end

        def settings_params
          params.permit(:basedirs_safe)
        end

        def settings_json(settings)
          { basedirs_safe: settings&.basedirs_safe? || false }
        end
      end
    end
  end
end
