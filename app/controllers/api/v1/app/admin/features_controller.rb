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
                end,
              work_unit_ownership: work_unit_ownership_payload
            }
          end

          def declared_features
            declarations = Features::SyncFromYaml.declarations.uniq { |d| d.fetch(:slug) }
            declarations = declarations.reject { |declaration| %w[coding_mode local_mode].include?(declaration.fetch(:slug)) } if AppSetting.simple?
            records = Feature.where(slug: declarations.map { |declaration| declaration.fetch(:slug) }).index_by(&:slug)

            declarations.map do |declaration|
              feature = records[declaration.fetch(:slug)] || Feature.new(
                slug: declaration.fetch(:slug),
                category: declaration.fetch(:category),
                name: declaration.fetch(:name),
                description: declaration[:description],
                default_enabled: declaration.fetch(:default_enabled),
                enabled: declaration.fetch(:default_enabled)
              )
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
              enabled: feature.enabled?,
              name_i18n_key: feature.name_i18n_key,
              description_i18n_key: feature.description_i18n_key
            }
          end

          def work_unit_ownership_payload
            WorkUnits::PathOwnership::PATH_GATES
              .keys
              .sort
              .map { |path| WorkUnits::PathOwnership.for(path) }
              .group_by(&:gate)
              .map do |gate, paths|
                gate_feature = declared_features.find { |feature| feature.slug == gate }
                {
                  gate: gate,
                  enabled: gate_feature&.enabled? || false,
                  paths: paths.map do |path|
                    {
                      path: path.path,
                      owner: path.owner.to_s,
                      gate: path.gate
                    }
                  end
                }
              end
          end

          def feature_params
            params.expect(feature: [ :enabled ])
          end
        end
      end
    end
  end
end
