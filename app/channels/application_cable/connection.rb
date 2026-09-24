module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    # Per-process live connection counts, so "five tabs from one user" (the
    # motivating EPIC-392 incident) is visible on the dashboard instead of
    # inferred from request-rate spikes after the fact. `cable_connections`
    # is this process's own live count -- not GLOBAL like the sampled
    # queue-health gauges, since each web pod really does hold a distinct set
    # of WebSocket connections; Prometheus sums it across pods normally.
    # `cable_connections_per_user_max` reports the busiest single user this
    # process currently has connected, deliberately never a per-user label
    # (see Syrus::Metrics::TagAllowlist -- `user_id` is forbidden as
    # unbounded), which is what actually shows multi-tab fan-out without
    # creating one series per user.
    CONNECTIONS_MUTEX = Mutex.new
    CONNECTIONS_PER_USER = Hash.new(0)

    def self.declare_metrics!
      Syrus::Metrics.declare do
        gauge :cable_connections, comment: "Live Action Cable connections held by this process"
        gauge :cable_connections_per_user_max, comment: "Busiest single user's live connection count on this process " \
                                                         "(never per-user labeled -- see EPIC-392 multi-tab fan-out)"
      end
    end
    declare_metrics!

    def connect
      set_current_user || reject_unauthorized_connection
      track_connected!
    end

    def disconnect
      track_disconnected!
    end

    private
      def set_current_user
        if session = Session.find_by(id: cookies.signed[:session_id])
          self.current_user = session.user
        elsif token = request.params[:api_token].presence
          self.current_user = User.find_by(api_token: token)
        end
      end

      def track_connected!
        Syrus::Metrics.gauge(:syrus_cable_connections).increment
        refresh_per_user_max! { |counts| counts[current_user.id] += 1 }
      end

      def track_disconnected!
        return unless current_user

        Syrus::Metrics.gauge(:syrus_cable_connections).decrement
        refresh_per_user_max! do |counts|
          remaining = counts[current_user.id] - 1
          remaining.positive? ? counts[current_user.id] = remaining : counts.delete(current_user.id)
        end
      end

      def refresh_per_user_max!
        max = CONNECTIONS_MUTEX.synchronize do
          yield CONNECTIONS_PER_USER
          CONNECTIONS_PER_USER.values.max || 0
        end
        Syrus::Metrics.gauge(:syrus_cable_connections_per_user_max).set(max)
      end
  end
end
