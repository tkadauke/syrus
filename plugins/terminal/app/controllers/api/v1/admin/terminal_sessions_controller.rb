module Api
  module V1
    module Admin
      # External admin API for interactive terminal sessions — the
      # same shape of surface as Api::V1::Admin::SpawnedProcessesController,
      # for a Terminal::Session (a live PTY on a worker pod) instead of a
      # SpawnedProcess.
      #
      #   GET  /api/v1/admin/terminal_sessions
      #     - ?state=running|finished
      #     - ?user=substring        — match User#email_address
      #     - ?hostname=<relay-host> — match the host portion of relay_address
      #   GET  /api/v1/admin/terminal_sessions/:id  — detail
      #   POST /api/v1/admin/terminal_sessions/:id/kill — kill the session,
      #        the same write path the app API's kill/destroy actions use.
      class TerminalSessionsController < BaseController
        DEFAULT_PER = 50
        MAX_PER     = 100

        def index
          scope = ::Terminal::Session.includes(:user, :workflow).order(started_at: :desc)
          scope = filter_by_state(scope)
          scope = scope.joins(:user).where("users.email_address LIKE ?", "%#{params[:user]}%") if params[:user].present?
          scope = scope.where("relay_address LIKE ?", "#{params[:hostname]}:%") if params[:hostname].present?

          per   = (params[:per].presence || DEFAULT_PER).to_i.clamp(1, MAX_PER)
          page  = [ params[:page].to_i, 1 ].max
          total = scope.count
          rows  = scope.offset((page - 1) * per).limit(per).to_a

          render json: {
            count: rows.size,
            total: total,
            page:  page,
            per:   per,
            sessions: rows.map { |session| serialize(session) }
          }
        end

        def show
          render json: serialize(::Terminal::Session.find(params[:id]))
        end

        def kill
          session = ::Terminal::Session.find(params[:id])
          ::Terminal::KillSession.call(session)
          render json: serialize(session.reload)
        end

        private

        def filter_by_state(scope)
          case params[:state]
          when "running"  then scope.running
          when "finished" then scope.finished
          else scope
          end
        end

        def serialize(session)
          ::Terminal::AdminSessionSerializer.render(session)
        end
      end
    end
  end
end
