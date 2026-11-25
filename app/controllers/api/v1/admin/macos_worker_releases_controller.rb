module Api
  module V1
    module Admin
      # The macOS worker release a deploy publishes for its revision (see
      # Deploy::MacosWorkers and MacosWorkerRelease).
      #
      #   POST /api/v1/admin/macos_worker_releases           - multipart: artifact, git_sha,
      #                                                         artifact_sha256, artifact_signature,
      #                                                         artifact_name, version, built_at
      #   POST /api/v1/admin/macos_worker_releases/activate  - git_sha: make it the release
      #                                                         every Mac worker runs
      #   GET  /api/v1/admin/macos_worker_releases/status    - the active release and where each
      #                                                         Mac worker stands
      class MacosWorkerReleasesController < BaseController
        rescue_from ArgumentError do |error|
          render_error("macos_worker_release_invalid", error.message, status: :bad_request)
        end
        rescue_from ::MacosWorkerRelease::DigestMismatch do |error|
          render_error("digest_mismatch", error.message, status: :unprocessable_content)
        end

        def create
          artifact = params.require(:artifact)
          blob = ::MacosWorkerRelease.store!(
            io: artifact,
            git_sha: params.require(:git_sha),
            sha256: params.require(:artifact_sha256),
            signature: params.require(:artifact_signature),
            artifact_name: params[:artifact_name].presence || artifact.original_filename,
            version: params[:version],
            full_git_sha: params[:full_git_sha],
            built_at: params[:built_at]
          )
          render json: { git_sha: blob.metadata["git_sha"], artifact_sha256: blob.metadata["sha256"], byte_size: blob.byte_size },
            status: :created
        end

        def activate
          release = ::MacosWorkerRelease.activate!(
            git_sha: params.require(:git_sha),
            base_url: ::MacosWorkerRelease.public_base_url(fallback: request.base_url)
          )
          render json: { desired: release }
        end

        def status
          render json: ::MacosWorkerRelease.status
        end
      end
    end
  end
end
