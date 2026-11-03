module Api
  module V1
    module App
      # Owner-only management of AI approval delegations. Agents holding a
      # workflow invocation credential can never create or revoke delegations:
      # an AI principal must not be able to expand its own authority.
      class ApprovalDelegationsController < BaseController
        before_action :reject_invocation_context

        def index
          render json: Permissions::ApprovalDelegationPayload.new(Current.user).as_json
        end

        def create
          attrs = delegation_params
          provider = Syrus::PluginRegistry.providers_for(:approval_provider)
            .find { |candidate| candidate.provider_key.to_s == attrs[:provider_key].to_s }
          return invalid(I18n.t("api.approval_delegations.provider_unavailable")) unless provider
          unless Permissions::Catalog.descriptors.any? { |descriptor| descriptor.capability == attrs[:capability].to_s }
            return invalid(I18n.t("api.approval_delegations.unknown_capability"))
          end
          if attrs[:resource_scope].blank?
            return invalid(I18n.t("api.approval_delegations.scope_required"))
          end

          delegation = Current.user.approval_provider_delegations.create!(attrs)
          render json: { delegation: payload_for(delegation) }, status: :created
        rescue ActiveRecord::RecordInvalid => error
          invalid(error.message)
        end

        def revoke
          delegation = Current.user.approval_provider_delegations.find(params[:id])
          delegation.revoke!(actor: Current.user)
          render json: { delegation: payload_for(delegation) }
        end

        private

        def invalid(message)
          render_error("invalid_approval_delegation", message, status: :unprocessable_entity)
        end

        def payload_for(delegation)
          Permissions::ApprovalDelegationPayload.new(Current.user).serialize_delegation(delegation)
        end

        def reject_invocation_context
          return unless current_invocation_context

          render_error("forbidden", I18n.t("api.base.invocation_scope_forbidden"), status: :forbidden)
        end

        def delegation_params
          params.require(:approval_delegation).permit(
            :provider_key, :capability, :resource_type, excluded_effects: [], resource_scope: {}
          ).to_h.symbolize_keys
        end
      end
    end
  end
end
