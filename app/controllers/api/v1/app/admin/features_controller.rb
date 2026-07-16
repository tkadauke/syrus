module Api
  module V1
    module App
      module Admin
        class FeaturesController < BaseController
          def index
            render json: features_payload
          end

          def update
            feature = declared_feature(params[:slug])
            return render_error("not_found", I18n.t("api.admin_features.not_found"), status: :not_found) unless feature

            if feature.update(enabled: feature_params.fetch(:enabled))
              render json: { feature: feature_payload(feature) }
            else
              render_error("validation_failed", feature.errors.full_messages.to_sentence,
                           status: :unprocessable_content)
            end
          end

          private

          def features_payload
            {
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
            records = Feature.where(slug: declarations.map { |declaration| declaration.fetch(:slug) }).index_by(&:slug)

            declarations.map do |declaration|
              records[declaration.fetch(:slug)] || Feature.new(
                slug: declaration.fetch(:slug),
                category: declaration.fetch(:category),
                name: declaration.fetch(:name),
                description: declaration[:description],
                default_enabled: declaration.fetch(:default_enabled),
                enabled: declaration.fetch(:default_enabled)
              )
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
              enabled: feature.enabled?
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
