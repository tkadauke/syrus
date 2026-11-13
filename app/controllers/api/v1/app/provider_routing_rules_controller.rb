module Api
  module V1
    module App
      class ProviderRoutingRulesController < BaseController
        include ProviderRoutingRuleSerialization
        include AgentProviderCatalogOptions

        def index
          scope = routing_rule_scope!
          return unless scope

          render json: routing_rule_payload(scope)
        end

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

        def reorder
          scope = routing_rule_scope!
          return unless scope

          rules = ProviderRoutingRule
            .where(scope_type: scope[:scope_type], scope_id: scope[:scope_id])
            .order(:position, :id)
            .to_a
          ordered_ids = provider_routing_reorder_ids
          if ordered_ids.sort != rules.map(&:id).sort
            render_error(
              "validation_failed",
              t("api.provider_routing_rules.errors.reorder_ids_mismatch"),
              status: :unprocessable_content
            )
            return
          end

          ProviderRoutingRule.transaction do
            rules.each_with_index do |rule, index|
              rule.update_columns(position: -(index + 1), updated_at: Time.current)
            end

            ordered_ids.each_with_index do |id, index|
              rule = rules.detect { |candidate| candidate.id == id }
              rule.update_columns(position: index + 1, updated_at: Time.current)
            end
          end

          render json: routing_rule_payload(scope)
        end

        # Dry-runs the effective routing rules against a Job the caller can see.
        # Same payload as the explain_provider_routing MCP tool. The scope only
        # gates access (same checks as the rules endpoints); the explanation always
        # covers every scope that applies to the target Job.
        def explain
          return unless routing_rule_scope!

          task_key = params.require(:task_key).to_s
          job = find_job_by_ref(policy_scope(Job).includes(:repository, :owner_user, :user), params.require(:target_job_id))
          render json: ProviderRouting::Explainer.call(
            job: job,
            task_key: task_key,
            workflow_trigger_kind: params[:workflow_trigger_kind].presence
          )
        end

        private

        def routing_rule_scope!
          if params[:job_id].present?
            job = find_job_by_ref(policy_scope(Job).includes(:repository), params[:job_id])
            return unless authorize_job_mutation!(job)

            {
              scope_type: "job",
              scope_id: job.id,
              job_id: job.id,
              repository_id: job.repository_id,
              user_id: job.effective_owner_id
            }
          elsif params[:repository_id].present?
            repository = policy_scope(Repository).find(params[:repository_id])
            return unless RepositoryPolicy.new(Current.user, repository).update?

            {
              scope_type: "repository",
              scope_id: repository.id,
              repository_id: repository.id,
              user_id: repository.user_id || Current.user.id
            }
          else
            { scope_type: "user", scope_id: Current.user.id, user_id: Current.user.id }
          end
        end

        def routing_rule_payload(scope)
          payload = {
            scope: provider_routing_scope_json(scope),
            provider_routing_rules: provider_routing_rules_json(**scope),
            inherited_provider_routing_context: provider_routing_inherited_context_json(scope),
            provider_routing_options: provider_routing_options_json(Current.user)
          }
          return payload unless scope[:job_id]

          job = policy_scope(Job).find(scope[:job_id])
          provider_options = agent_provider_catalog_options(Current.user).fetch(:agent_providers)
          payload.merge(
            job_provider_setting_options: Job.provider_settings.map do |setting|
              option = provider_options.find { |candidate| candidate[:value] == setting }
              {
                value: setting,
                label: setting == "default" ? "Default" : ::App::Presentation.agent_provider_label(setting),
                configured: setting == "default" || Current.user.agent_provider_configured?(setting),
                models: option ? option[:models] : []
              }
            end,
            provider_routing_resolution: ProviderRouting::Resolver.resolve(
              job: job,
              task_key: job.latest_workflow&.trigger_kind.presence || "initial",
              workflow_trigger_kind: job.latest_workflow&.trigger_kind.presence || "initial"
            ).explanation,
            active_provider_routing_holds: ProviderRoutingHold.active.where(workflow_id: job.workflows.select(:id)).order(:created_at).map do |hold|
              {
                id: hold.id, workflow_id: hold.workflow_id, provider_routing_rule_id: hold.provider_routing_rule_id,
                reason: hold.reason, resumption_mode: hold.resumption_mode,
                next_reevaluation_at: hold.next_reevaluation_at&.iso8601, created_at: hold.created_at.iso8601
              }
            end
          )
        end
      end
    end
  end
end
