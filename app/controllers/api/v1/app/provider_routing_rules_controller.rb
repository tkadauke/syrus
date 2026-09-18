module Api
  module V1
    module App
      class ProviderRoutingRulesController < BaseController
        include ProviderRoutingRuleSerialization

        def create
          scope = routing_rule_scope!
          return unless scope

          rule = ProviderRoutingRule.new(provider_routing_rule_attrs.merge(scope))
          if rule.save
            render json: routing_rule_payload(scope), status: :created
          else
            render_error("validation_failed", rule.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def update
          scope = routing_rule_scope!
          return unless scope

          rule = ProviderRoutingRule.find_by!(scope.merge(id: params[:id]))
          if rule.update(provider_routing_rule_attrs)
            render json: routing_rule_payload(scope)
          else
            render_error("validation_failed", rule.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def destroy
          scope = routing_rule_scope!
          return unless scope

          ProviderRoutingRule.find_by!(scope.merge(id: params[:id])).destroy!
          render json: routing_rule_payload(scope)
        end

        private

        def routing_rule_scope!
          if params[:repository_id].present?
            repository = policy_scope(Repository).find(params[:repository_id])
            return unless RepositoryPolicy.new(Current.user, repository).update?

            { scope_type: "repository", scope_id: repository.id }
          else
            { scope_type: "user", scope_id: Current.user.id }
          end
        end

        def routing_rule_payload(scope)
          {
            provider_routing_rules: provider_routing_rules_json(**scope),
            provider_routing_options: agent_provider_catalog_options(Current.user)
          }
        end
      end
    end
  end
end
