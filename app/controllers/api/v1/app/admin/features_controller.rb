module Api
  module V1
    module App
      module Admin
        class FeaturesController < BaseController
          # Declared and functional (toggleable via Rails console) but
          # deliberately excluded from both the visible Labs feature list and
          # this controller's own `update` action: these are unfinished or
          # otherwise not meant to be discoverable as a self-hoster-facing
          # toggle yet.
          ALWAYS_HIDDEN_SLUGS = [].freeze

          def index
            render json: features_payload
          end

          def update
            feature = declared_feature(params[:slug])
            return render_error("not_found", I18n.t("api.admin_features.not_found"), status: :not_found) unless feature

            if feature.update(enabled: feature_params.fetch(:enabled))
              render json: { feature: feature_payload(feature) }
            else
              if feature.errors.added?(:enabled, "requires beta mode for beta or experimental features")
                render json: {
                  error: {
                    code: "beta_mode_not_enabled",
                    message: "This feature is available in this Syrus build, but this instance has not enabled beta mode."
                  },
                  message: "This feature is available in this Syrus build, but this instance has not enabled beta mode.",
                  blocked_experimental_features: [
                    { slug: feature.slug, name: feature.name }
                  ]
                }, status: :unprocessable_content
                return
              end

              render_error("validation_failed", feature.errors.full_messages.to_sentence,
                           status: :unprocessable_content)
            end
          end

          private

          def features_payload
            {
              beta_mode_enabled: AppSetting.beta_mode_enabled?,
              categories: declared_features
                .group_by(&:category)
                .map do |category, features|
                  {
                    category: category,
                    features: features.map { |feature| feature_payload(feature) }
                  }
                end
            }
          end

          def declared_features
            declarations = Features::SyncFromYaml.declarations.uniq { |d| d.fetch(:slug) }
            declarations = declarations.reject { |declaration| ALWAYS_HIDDEN_SLUGS.include?(declaration.fetch(:slug)) }
            records = Feature.where(slug: declarations.map { |declaration| declaration.fetch(:slug) }).index_by(&:slug)

            declarations.map do |declaration|
              feature = records[declaration.fetch(:slug)] || Feature.new(
                slug: declaration.fetch(:slug),
                category: declaration.fetch(:category),
                name: declaration.fetch(:name),
                description: declaration[:description],
                default_enabled: declaration.fetch(:default_enabled),
                enabled: declaration.fetch(:default_enabled),
                experimental: declaration.fetch(:experimental, false)
              )
              feature.experimental = declaration.fetch(:experimental, false) if feature.has_attribute?(:experimental)
              feature.name_i18n_key = declaration[:name_i18n_key]
              feature.description_i18n_key = declaration[:description_i18n_key]
              feature
            end
          end

          def declared_feature(slug)
            feature = declared_features.find { |declared| declared.slug == slug.to_s }
            return unless feature
            return feature if feature.persisted?

            feature.save!
            feature
          end

          def feature_payload(feature)
            {
              slug: feature.slug,
              category: feature.category,
              name: feature.name,
              description: feature.description,
              experimental: feature.experimental?,
              enabled: feature.effective_enabled?,
              name_i18n_key: feature.name_i18n_key,
              description_i18n_key: feature.description_i18n_key
            }
          end

          def feature_params
            params.expect(feature: [ :enabled ])
          end
        end
      end
    end
  end
end
