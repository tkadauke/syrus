module Api
  module V1
    module App
      # Chat-independent access to a preview panel.
      #
      # Every panel route used to live under `chats/:id/preview_panels/...`,
      # which meant a panel could only be shown inside the chat it was opened
      # in. A plugin that lists panels on its own page (mockups) needs the same
      # content without inventing its own file-serving or its own access rule --
      # so the rule moved onto the model (`PreviewPanel.accessible_to`) and
      # these actions mirror the chat ones exactly.
      class PreviewPanelsController < BaseController
        def show
          panel = find_panel
          return if performed?

          render json: PreviewPanel::Payload.new(panel).as_json
        end

        def file
          panel = find_panel
          return if performed?

          version = resolve_version(panel)
          return if performed?

          path = params[:path].to_s
          attachment = version.file_for(path)
          return render_error("not_found", "Preview panel file not found.", status: :not_found) unless attachment

          content_type = Marcel::MimeType.for(name: attachment.blob.metadata["relative_path"].to_s)
          if ActiveModel::Type::Boolean.new.cast(params[:raw])
            return send_data attachment.download, type: content_type, disposition: "inline", filename: File.basename(path)
          end

          if text_content_type?(content_type, path)
            render json: { content: attachment.download.force_encoding(Encoding::UTF_8), binary: false, too_large: false, content_type: content_type }
          else
            render json: { content: nil, binary: true, too_large: false, content_type: content_type }
          end
        end

        def export
          panel = find_panel
          return if performed?

          version = resolve_version(panel)
          return if performed?

          send_data(
            PreviewPanel::ZipExporter.new(version).call,
            filename: "#{panel.title.parameterize.presence || 'preview'}.zip",
            type: "application/zip",
            disposition: "attachment"
          )
        end

        def token
          panel = find_panel
          return if performed?

          if panel.public?
            return render_error("validation_failed", "Public panels don't require an access token.", status: :unprocessable_content)
          end

          render json: { token: PreviewPanel::AccessToken.issue(panel), expires_in: PreviewPanel::AccessToken::TTL.to_i }
        end

        private

        def find_panel
          panel = PreviewPanel.accessible_to(Current.user).find_by(id: params[:id])
          render_error("not_found", "Preview panel not found.", status: :not_found) if panel.nil?
          panel
        end

        def resolve_version(panel)
          version = params[:v].present? ? panel.preview_panel_versions.find_by(id: params[:v]) : panel.current_version
          render_error("not_found", "Preview panel version not found.", status: :not_found) if version.nil?
          version
        end

        def text_content_type?(content_type, path)
          PreviewPanel::EntryMetadata.markdown_path?(path) ||
            content_type.start_with?("text/") ||
            %w[application/json application/javascript image/svg+xml].include?(content_type)
        end
      end
    end
  end
end
