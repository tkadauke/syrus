require "fugit"

module Schedules
  class RecurringSchedule
    Result = Data.define(:valid?, :input, :format, :expression, :timezone, :explanation, :next_fire_at, :cron_expression, :errors, :source, :structured_intent)

    DAYS = {
      "sunday" => "SU", "sundays" => "SU", "sun" => "SU",
      "monday" => "MO", "mondays" => "MO", "mon" => "MO",
      "tuesday" => "TU", "tuesdays" => "TU", "tue" => "TU", "tues" => "TU",
      "wednesday" => "WE", "wednesdays" => "WE", "wed" => "WE",
      "thursday" => "TH", "thursdays" => "TH", "thu" => "TH", "thur" => "TH", "thurs" => "TH",
      "friday" => "FR", "fridays" => "FR", "fri" => "FR",
      "saturday" => "SA", "saturdays" => "SA", "sat" => "SA"
    }.freeze
    DAY_NAMES = { "SU" => "Sunday", "MO" => "Monday", "TU" => "Tuesday", "WE" => "Wednesday", "TH" => "Thursday", "FR" => "Friday", "SA" => "Saturday" }.freeze
    MONTHS = Date::MONTHNAMES.each_with_index.filter_map { |name, index| [ name.downcase, index ] if name }.to_h.freeze
    MIN_INTERVAL = 1.hour

    # A cron field is a comma-separated list of `*` or integers, each
    # optionally range- (`1-5`) and/or step- (`*/2`, `1-5/2`) qualified. This
    # only needs to distinguish "looks like cron syntax" from "looks like
    # words" — Fugit (and the rescue wrapper around parse_cron) still does
    # real validation, so a malformed-but-digit-shaped field like day 0 still
    # surfaces as a clean "not a valid cron expression" error instead of
    # silently falling through to natural-language parsing.
    CRON_TERM = /(?:\*|\d+)(?:-\d+)?(?:\/\d+)?/
    CRON_FIELD = /\A#{CRON_TERM}(?:,#{CRON_TERM})*\z/

    class << self
      # Strict recognizer used to route input to the cron parser instead of
      # natural-language parsing. Five whitespace-separated tokens is not
      # enough on its own ("Every day at 10 am" is five tokens) — every field
      # must independently look like a cron field.
      def cron_shaped?(value)
        fields = value.to_s.strip.split(/\s+/)
        fields.size == 5 && fields.all? { |field| field.match?(CRON_FIELD) }
      end

      def preview(input:, structured_intent: nil, from: Time.current)
        new(input: input, structured_intent: structured_intent, from: from).preview
      end

      def explain(expression, timezone: "UTC")
        from_expression(expression, timezone: timezone).explanation
      end

      def next_fire_at(expression, timezone: "UTC", from: Time.current)
        from_expression(expression, timezone: timezone).next_fire_at(from: from)
      end

      def due_window_start(expression, timezone: "UTC", now: Time.current)
        from_expression(expression, timezone: timezone).due_window_start(now: now)
      end

      def from_expression(expression, timezone: "UTC")
        Schedule.new(parse_rrule(expression), timezone: timezone.presence || "UTC", input: expression)
      end
    end

    def initialize(input:, structured_intent: nil, from: Time.current)
      @input = input.to_s.strip
      @structured_intent = structured_intent
      @from = from
    end

    def preview
      schedule = parse_input
      return invalid(@input.present? ? "Schedule input is not a supported cadence or five-field cron expression" : "Schedule is required") unless schedule

      errors = schedule.validation_errors
      if errors.any?
        invalid(errors.join(", "))
      else
        Result.new(
          valid?: true,
          input: @input,
          format: "rrule",
          expression: schedule.expression,
          timezone: schedule.timezone,
          explanation: schedule.explanation,
          next_fire_at: schedule.next_fire_at(from: @from)&.iso8601,
          cron_expression: schedule.cron_expression,
          errors: [],
          source: @source,
          structured_intent: @structured_intent
        )
      end
    rescue ArgumentError => e
      invalid(e.message)
    end

    private

    def invalid(message)
      Result.new(valid?: false, input: @input, format: "rrule", expression: nil, timezone: "UTC", explanation: nil, next_fire_at: nil, cron_expression: nil, errors: [ message ], source: nil, structured_intent: nil)
    end

    def parse_input
      if @structured_intent.present?
        @source = "structured_intent"
        return parse_structured_intent(@structured_intent)
      end

      if self.class.cron_shaped?(@input)
        @source = "cron"
        return parse_cron(@input)
      end

      @source = "natural"
      parse_natural(@input)
    end

    def parse_cron(value)
      fields = value.split(/\s+/)
      cron = Fugit.parse("#{value} UTC")
      raise ArgumentError, "is not a valid five-field cron expression" unless cron.is_a?(Fugit::Cron)

      minute, hour, day_of_month, month, day_of_week = fields
      parts = [ "FREQ=#{frequency_for(hour, day_of_month, month, day_of_week)}" ]
      parts << "BYMONTH=#{month}" unless month == "*"
      parts << "BYMONTHDAY=#{day_of_month}" unless day_of_month == "*"
      parts << "BYDAY=#{rrule_days(day_of_week)}" unless day_of_week == "*"
      parts << "BYHOUR=#{hour}" unless hour == "*"
      parts << "BYMINUTE=#{minute}"
      parts << "BYSECOND=0"
      Schedule.new(self.class.parse_rrule(parts.join(";")), timezone: "UTC", input: value, cron_expression: value)
    rescue ArgumentError
      raise
    rescue StandardError
      raise ArgumentError, "is not a valid five-field cron expression"
    end

    def parse_natural(value)
      normalized = value.downcase.squish
      if (match = normalized.match(/\A(?:every\s+)?(?:day|daily)\s+at\s+(.+)\z/))
        return schedule(freq: "DAILY", hour_minute: parse_time(match[1]))
      end

      if (match = normalized.match(/\A(?:every\s+)?([a-z]+)s?\s+at\s+(.+)\z/))
        day = DAYS.fetch(match[1], nil)
        return schedule(freq: "WEEKLY", day: day, hour_minute: parse_time(match[2])) if day
      end

      if (match = normalized.match(/\A(?:every\s+)?(?:year|yearly|annually|annual)\s+([a-z]+)\s+(\d{1,2})\s+at\s+(.+)\z/))
        month = MONTHS.fetch(match[1], nil)
        return schedule(freq: "YEARLY", month: month, month_day: match[2].to_i, hour_minute: parse_time(match[3])) if month
      end

      nil
    end

    def parse_structured_intent(intent)
      values = intent.to_h.transform_keys(&:to_s)
      freq = values.fetch("frequency", "").to_s.upcase
      raise ArgumentError, "frequency must be HOURLY, DAILY, WEEKLY, MONTHLY, or YEARLY" unless %w[HOURLY DAILY WEEKLY MONTHLY YEARLY].include?(freq)

      day = normalize_structured_day(values["day"])
      hour_minute = [ safe_integer(values["hour"], "hour"), safe_integer(values["minute"].presence || 0, "minute") ]
      month = values["month"].presence && safe_integer(values["month"], "month")
      month_day = values["month_day"].presence && safe_integer(values["month_day"], "month day")
      schedule(freq: freq, day: day, month: month, month_day: month_day, hour_minute: hour_minute)
    end

    def normalize_structured_day(value)
      return nil if value.blank?

      DAYS.fetch(value.to_s.downcase) { raise ArgumentError, "day must be a day of the week" }
    end

    # Never let Ruby's core Integer() exception text ("invalid value for
    # Integer(): \"am\"") reach a user-facing preview response — always raise
    # our own friendly ArgumentError instead.
    def safe_integer(value, label)
      raise ArgumentError, "#{label} is required" if value.nil? || value == ""

      begin
        Integer(value)
      rescue ArgumentError, TypeError
        raise ArgumentError, "#{label} must be a whole number"
      end
    end

    def schedule(freq:, hour_minute:, day: nil, month: nil, month_day: nil)
      hour, minute = hour_minute
      parts = [ "FREQ=#{freq}" ]
      parts << "BYMONTH=#{month}" if month
      parts << "BYMONTHDAY=#{month_day}" if month_day
      parts << "BYDAY=#{day}" if day
      parts << "BYHOUR=#{hour}"
      parts << "BYMINUTE=#{minute}"
      parts << "BYSECOND=0"
      Schedule.new(self.class.parse_rrule(parts.join(";")), timezone: "UTC", input: @input)
    end

    def parse_time(value)
      match = value.to_s.strip.match(/\A(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\z/)
      raise ArgumentError, "time must look like 9, 9:30, 9am, or 14:30" unless match

      hour = Integer(match[1])
      minute = Integer(match[2] || 0)
      suffix = match[3]
      hour = 0 if suffix == "am" && hour == 12
      hour += 12 if suffix == "pm" && hour < 12
      [ hour, minute ]
    end

    def frequency_for(hour, day_of_month, month, day_of_week)
      return "HOURLY" if hour == "*" && day_of_month == "*" && month == "*" && day_of_week == "*"
      return "YEARLY" unless month == "*"
      return "MONTHLY" unless day_of_month == "*"
      return "WEEKLY" unless day_of_week == "*"

      "DAILY"
    end

    def rrule_days(value)
      names = %w[SU MO TU WE TH FR SA]
      value.split(",").map { |day| names.fetch(Integer(day) % 7) }.join(",")
    end

    def self.parse_rrule(expression)
      attrs = expression.to_s.delete_prefix("RRULE:").split(";").filter_map do |part|
        key, value = part.split("=", 2)
        [ key, value ] if key.present? && value.present?
      end.to_h
      raise ArgumentError, "schedule expression is not a valid RRULE" if attrs["FREQ"].blank?

      attrs
    end

    class Schedule
      def initialize(attrs, timezone:, input:, cron_expression: nil)
        @attrs = attrs
        @timezone = timezone
        @input = input
        @cron_expression = cron_expression
      end

      attr_reader :timezone, :cron_expression

      def expression
        ordered = %w[FREQ BYMONTH BYMONTHDAY BYDAY BYHOUR BYMINUTE BYSECOND]
        ordered.filter_map { |key| "#{key}=#{@attrs[key]}" if @attrs[key].present? }.join(";")
      end

      def explanation
        "#{cadence_label} at #{time_label} #{@timezone}"
      end

      def next_fire_at(from: Time.current)
        from = from.utc
        if freq == "HOURLY"
          candidate = from.change(min: minute, sec: 0, usec: 0)
          candidate += 1.hour if candidate <= from
          return candidate
        end

        date = from.to_date
        1_830.times do |offset|
          candidate_date = date + offset
          candidate = Time.utc(candidate_date.year, candidate_date.month, candidate_date.day, hour, minute)
          return candidate if candidate > from && matches?(candidate)
        end
        nil
      end

      def due_window_start(now: Time.current)
        window_start = now.utc.change(min: 0, sec: 0, usec: 0)
        tick = first_tick_in_window(window_start)
        return nil unless tick && tick <= now

        window_start
      end

      def validation_errors
        errors = []
        errors << "timezone must be UTC" unless @timezone == "UTC"
        errors << "frequency must be HOURLY, DAILY, WEEKLY, MONTHLY, or YEARLY" unless %w[HOURLY DAILY WEEKLY MONTHLY YEARLY].include?(freq)
        errors << "hour must be between 0 and 23" if hour && !hour.between?(0, 23)
        errors << "minute must be between 0 and 59" unless minute.between?(0, 59)
        errors << "day is required for weekly schedules" if freq == "WEEKLY" && days.empty?
        errors << "month day is required for monthly schedules" if freq == "MONTHLY" && month_day.nil?
        errors << "month and month day are required for yearly schedules" if freq == "YEARLY" && (month.nil? || month_day.nil?)
        errors << "month must be between 1 and 12" if month && !month.between?(1, 12)
        errors << "month day must be between 1 and 31" if month_day && !month_day.between?(1, 31)
        errors << "must fire at most once per hour" if multiple_ticks_per_hour?
        errors << "does not produce a future scheduled time" if errors.empty? && next_fire_at(from: Time.utc(2026, 1, 1)).nil?
        errors
      end

      private

      def first_tick_in_window(window_start)
        60.times do |offset|
          tick = window_start + offset.minutes
          return tick if matches?(tick)
        end
        nil
      end

      def multiple_ticks_per_hour?
        @attrs.fetch("BYMINUTE", "").include?(",") || @attrs.fetch("BYMINUTE", "").include?("-") || @attrs.fetch("BYMINUTE", "").include?("/")
      end

      def matches?(time)
        return false unless time.min == minute
        return false if hour && time.hour != hour
        return false if month && time.month != month
        return false if month_day && time.day != month_day
        return false if days.any? && !days.include?(%w[SU MO TU WE TH FR SA][time.wday])

        true
      end

      def cadence_label
        return "Every hour" if freq == "HOURLY"
        return "Every day" if freq == "DAILY"
        return "Every #{days.map { |day| DAY_NAMES.fetch(day, day) }.to_sentence}" if freq == "WEEKLY"
        return "Every month on day #{month_day}" if freq == "MONTHLY"

        "Every #{Date::MONTHNAMES.fetch(month)} #{month_day}"
      end

      def time_label
        return "#{minute.to_s.rjust(2, '0')} minutes past the hour" if freq == "HOURLY"

        Time.utc(2026, 1, 1, hour, minute).strftime("%-I:%M %p")
      end

      def freq = @attrs["FREQ"].to_s.upcase
      def hour = @attrs.key?("BYHOUR") ? Integer(@attrs["BYHOUR"], exception: false) : nil
      def minute = Integer(@attrs.fetch("BYMINUTE", -1), exception: false) || -1
      def month = Integer(@attrs["BYMONTH"], exception: false)
      def month_day = Integer(@attrs["BYMONTHDAY"], exception: false)
      def days = @attrs.fetch("BYDAY", "").split(",").compact_blank
    end
  end
end
