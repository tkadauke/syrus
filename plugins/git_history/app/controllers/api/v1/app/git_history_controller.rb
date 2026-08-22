module Api
  module V1
    module App
      class GitHistoryController < BaseController
        def index
          repository = find_repository
          limit = params.fetch(:limit, ::GitHistory::Commits::DEFAULT_LIMIT).to_i.clamp(1, ::GitHistory::Commits::MAX_LIMIT)

          result = ::GitHistory::Commits.call(
            repository: repository,
            user: Current.user,
            cursor: params[:cursor],
            limit: limit
          )

          render json: {
            repository: { id: repository.id, slug: repository.slug },
            available: result.available,
            commits: result.commits,
            next_cursor: result.next_cursor,
            has_more: result.has_more
          }
        end

        private

        def find_repository
          Repository.accessible_to(Current.user).find(params[:repository_id])
        end
      end
    end
  end
end
