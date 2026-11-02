module ApprovalNotifications
  class Router
    def self.route!(request, now: Time.current) = new(request, now:).route!

    def initialize(request, now: Time.current)
      @request = request
      @now = now
    end

    def route!
      preferences = request.user.approval_delivery_preferences
      unless preferences.fetch("enabled")
        request.record_delivery!(metadata: { "channel" => "external", "suppressed" => "preference" }, at: now)
        return
      end

      urgency = request.authorization_items.map { |item| Urgency.for(item.risk) }
        .max_by { |value| Urgency::LEVELS.fetch(value.name) } || Urgency::Normal.new
      deliver_at = now
      deliver_at += preferences.fetch("batch_minutes").minutes if urgency.batch?
      deliver_at = quiet_hours_end(deliver_at, preferences)
      request.update!(
        delivery_state: "queued",
        delivery_metadata: request.delivery_metadata.merge("channel" => "external", "urgency" => urgency.name, "deliver_after" => deliver_at.iso8601)
      )
      ApprovalNotificationDeliveryJob.set(wait_until: deliver_at).perform_later(request.id)
    rescue => error
      request.record_delivery_failure!(error, metadata: { "channel" => "external" })
      raise
    end

    private

    attr_reader :request, :now

    def quiet_hours_end(candidate, preferences)
      return candidate unless preferences.fetch("quiet_hours_enabled")

      zone = ActiveSupport::TimeZone[preferences.fetch("time_zone")] || ActiveSupport::TimeZone["UTC"]
      local = candidate.in_time_zone(zone)
      start_minutes = minutes(preferences.fetch("quiet_hours_start"))
      end_minutes = minutes(preferences.fetch("quiet_hours_end"))
      return candidate if start_minutes == end_minutes

      current_minutes = local.hour * 60 + local.min
      in_quiet_hours = start_minutes < end_minutes ? current_minutes.between?(start_minutes, end_minutes - 1) : current_minutes >= start_minutes || current_minutes < end_minutes
      return candidate unless in_quiet_hours

      end_date = local.to_date
      end_date += 1.day if start_minutes >= end_minutes && current_minutes >= start_minutes
      zone.local(end_date.year, end_date.month, end_date.day, end_minutes / 60, end_minutes % 60)
    end

    def minutes(value)
      hour, minute = value.split(":").map(&:to_i)
      hour * 60 + minute
    end
  end
end
