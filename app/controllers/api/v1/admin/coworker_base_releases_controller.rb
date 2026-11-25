module Api
  module V1
    module Admin
      # Promotion, rollback, support windows, and emergency revocation of the
      # standard coworker base. Every change is audited with the acting admin.
      #
      #   GET  /api/v1/admin/coworker_base_releases               - releases, launch state per platform,
      #                                                             environments needing a rebuild
      #   POST /api/v1/admin/coworker_base_releases/:id/promote   - make a candidate the active base
      #   POST /api/v1/admin/coworker_base_releases/rollback      - platform, optional release_id
      #   POST /api/v1/admin/coworker_base_releases/:id/revoke    - reason, severity (standard|severe)
      #   POST /api/v1/admin/coworker_base_releases/:id/support   - supported_until (null clears)
      class CoworkerBaseReleasesController < BaseController
        rescue_from RuntimeImages::BaseReleases::Refused do |error|
          render_error(error.codes.first || "base_release_refused", error.message, status: :unprocessable_content)
        end
        rescue_from RuntimeImages::Error, ArgumentError do |error|
          render_error("base_release_invalid", error.message, status: :unprocessable_content)
        end

        def index
          health = RuntimeImages::Health.new
          releases = CoworkerBaseRelease.includes(:runtime_image).newest_first.limit(100).map { |release| health.base_release_json(release) }
          render json: health.base_snapshot.merge(releases: releases)
        end

        def promote
          render json: json_for(releases.promote!(release, actor: actor))
        end

        def rollback
          target = CoworkerBaseRelease.find(params[:release_id]) if params[:release_id].present?
          render json: json_for(releases.rollback!(platform: params[:platform].presence || RuntimeImages::BuiltImages::DEFAULT_PLATFORM, to: target, actor: actor))
        end

        def revoke
          render json: json_for(releases.revoke!(release, reason: params[:reason], severity: params[:severity].presence || "standard", actor: actor))
        end

        def support
          until_time = params[:supported_until].present? ? Time.zone.parse(params[:supported_until].to_s) : nil
          raise ArgumentError, "supported_until is not a valid time" if params[:supported_until].present? && until_time.nil?
          render json: json_for(releases.set_support_deadline!(release, until_time: until_time, actor: actor))
        end

        private

        def releases = RuntimeImages::BaseReleases.new
        def release = CoworkerBaseRelease.find(params[:id])
        def actor = "user:#{current_api_user.id}"
        def json_for(record) = RuntimeImages::Health.new.base_release_json(record)
      end
    end
  end
end
