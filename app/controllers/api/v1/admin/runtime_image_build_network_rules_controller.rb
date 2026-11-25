module Api
  module V1
    module Admin
      # Administrator-declared build-network allowlist for runtime image builds.
      # A build can reach only hosts an enabled rule here names; edits apply to
      # the next build.
      #
      #   GET    /api/v1/admin/runtime_image_build_network_rules      - rules, source classes, ecosystems
      #   POST   /api/v1/admin/runtime_image_build_network_rules
      #   PATCH  /api/v1/admin/runtime_image_build_network_rules/:id
      #   DELETE /api/v1/admin/runtime_image_build_network_rules/:id
      class RuntimeImageBuildNetworkRulesController < BaseController
        PERMITTED = %i[source_class host port path_prefix ecosystem required enabled note].freeze

        def index
          render json: {
            rules: RuntimeImageBuildNetworkRule.order(:source_class, :host, :port).map { |rule| serialize(rule) },
            source_classes: RuntimeImages::BuildNetwork::SourceClass.registry.values.map { |klass| describe(klass.new) },
            language_ecosystems: RuntimeImages::BuildNetwork::SourceClass::LanguageRegistry::ECOSYSTEMS
          }
        end

        def create
          rule = RuntimeImageBuildNetworkRule.new(rule_params.merge(actor: actor))
          save(rule, status: :created)
        end

        def update
          rule = RuntimeImageBuildNetworkRule.find(params[:id])
          rule.assign_attributes(rule_params.merge(actor: actor))
          save(rule, status: :ok)
        end

        def destroy
          RuntimeImageBuildNetworkRule.find(params[:id]).destroy!
          head :no_content
        end

        private

        def save(rule, status:)
          if rule.save
            render json: serialize(rule), status: status
          else
            render_error("validation_failed", rule.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        def rule_params
          params.permit(*PERMITTED).to_h.symbolize_keys
        end

        def actor = "user:#{current_api_user.id}"

        def serialize(rule)
          rule.slice(*%w[id source_class host port path_prefix ecosystem required enabled note actor created_at updated_at])
        end

        def describe(source)
          { key: source.class.key, ecosystem_required: source.ecosystem_required?, path_scoped: source.path_scoped?,
            allows_private_addresses: source.allow_private?, requirable: source.requirable?,
            displaced_by_required_mirror: source.displaced_by_required_mirror? }
        end
      end
    end
  end
end
