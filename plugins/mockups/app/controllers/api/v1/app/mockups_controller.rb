module Api
  module V1
    module App
      class MockupsController < BaseController
        PER_PAGE = 30

        def index
          filter = Mockups::Filter.from_params(params, user: Current.user)
          scope = filter.apply(base_scope).recent_first

          total = scope.count
          page = [ params[:page].to_i, 1 ].max
          rows = scope.offset((page - 1) * PER_PAGE).limit(PER_PAGE + 1).to_a
          has_next = rows.size > PER_PAGE
          rows = rows.first(PER_PAGE)

          render json: {
            mockups: rows.map { |mockup| summary_json(mockup) },
            filter: filter.as_tree,
            filter_schema: ::Filters::Schema.for(subject: :mockup, user: Current.user),
            pagination: { page: page, per_page: PER_PAGE, total: total, has_next_page: has_next, has_previous_page: page > 1 }
          }
        end

        def show
          mockup = Mockups::Mockup.find_by_ref(params[:id])
          mockup = nil unless mockup && base_scope.exists?(id: mockup.id)
          return render_error("not_found", "Mockup not found.", status: :not_found) if mockup.nil?

          render json: {
            mockup: summary_json(mockup),
            # The panel is core's; this is the same payload the chat sidebar
            # renders, pointed at the chat-independent panel routes.
            panel: PreviewPanel::Payload.new(mockup.preview_panel, scheme: request.ssl? ? "https" : "http").as_json
          }
        end

        private

        # A mockup is visible to whoever can see the panel behind it, which is
        # the panel's own rule -- not a second, looser one defined here.
        def base_scope
          Mockups::Mockup
            .where(preview_panel_id: PreviewPanel.accessible_to(Current.user).select(:id))
            .includes(preview_panel: { preview_panel_versions: { files_attachments: :blob } })
        end

        def summary_json(mockup)
          version = mockup.preview_panel&.current_version
          {
            id: mockup.id,
            slug: mockup.slug,
            title: mockup.title,
            preview_panel_id: mockup.preview_panel_id,
            chat_session_id: mockup.chat_session_id,
            entry_viewer_kind: version&.entry_viewer_kind || "html",
            file_count: version&.files&.size || 0,
            published_at: mockup.published_at&.iso8601,
            updated_at: mockup.updated_at&.iso8601,
            app_path: "/mockups/#{mockup.slug}"
          }
        end
      end
    end
  end
end
