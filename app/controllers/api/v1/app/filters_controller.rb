module Api
  module V1
    module App
      class FiltersController < BaseController
        def usage
          ::Filters::Suggestions.record!(
            user: Current.user,
            surface: params[:surface].presence || "dashboard",
            subject: params[:subject].presence || "job",
            tree: usage_tree
          )

          render json: { recorded: true }
        rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked => e
          Rails.logger.warn("[Filters::Suggestions] skipped usage recording: #{e.class}: #{e.message}")
          render json: { recorded: false }
        rescue ArgumentError
          render_error("invalid_filter_usage", I18n.t("api.filters.invalid_usage"), status: :bad_request)
        end

        def suggestions
          render json: {
            suggestions: ::Filters::SuggestionSearch.call(
              user: Current.user,
              surface: params[:surface].presence || "dashboard",
              subject: params[:subject].presence || "job",
              query: params[:q],
              active_tree: ::Filters::QueryParam.decode(params[:active_q])
            )
          }
        rescue ArgumentError
          render_error("invalid_filter_suggestions", I18n.t("api.filters.invalid_suggestions"), status: :bad_request)
        end

        def fk_options
          resolver = ::Filters::FkOptionsResolver.new(user: Current.user)
          render json: {
            options: resolver.resolve(field: params[:field], q: params[:q], ids: params[:ids])
          }
        rescue ::Filters::FkOptionsResolver::UnknownField
          render_error("unknown_field", I18n.t("api.filters.unknown_field"), status: :bad_request)
        end

        private

        def usage_tree
          if params.key?(:filter)
            filter = params.require(:filter)
            raise ArgumentError unless filter.respond_to?(:to_unsafe_h)

            filter.to_unsafe_h
          else
            ::Filters::QueryParam.decode(params[:q])
          end
        end
      end
    end
  end
end
