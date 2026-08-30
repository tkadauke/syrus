module Timeline
  # Parses the worker-timeline macro view's shared FilterBar query-tree
  # (`?q=` base64-JSON, same wire format as the dashboard/admin filter
  # bars -- see Filters::QueryParam) into the discrete
  # repository_id/epic_id/hostname/status/job_type/from/to arguments MacroQuery
  # already accepts, and builds the `filter_schema` payload the shared
  # FilterBar component (app/frontend/components/FilterBar.tsx) renders
  # against.
  #
  # This is deliberately not a Filters::Registry subject: MacroQuery
  # isn't a single AR relation a Filters::Compiler chip can `.where`
  # against (spans come from Workflow, pending from a second Workflow
  # scope, idle lanes from InstanceVersion, and the "window" isn't a
  # plain column comparison -- it's an overlap test applied across all
  # three). So this only understands a flat top-level AND of chips (the
  # shape FilterBar produces for this small, fixed field set); chips
  # nested in an OR group or wrapped in NOT are ignored.
  class MacroQueryFilter
    STATUSES = %w[ queued running succeeded failed cancelled ].freeze
    JOB_TYPES = [
      { "value" => "user", "label" => "User" },
      { "value" => "system", "label" => "Infrastructure" }
    ].freeze

    # No "window" chip applied -> every worker lane and every workflow
    # from the last 3 hours (issue default; independent of
    # MacroQuery::DEFAULT_WINDOW, which stays the documented 1-hour
    # default for the separate bearer-token /api/v1/timeline/macro API).
    DEFAULT_WINDOW = 3.hours

    def self.schema
      [
        { "field" => "repository_id", "label" => "Repository", "bucket" => "fk", "operators" => %w[ is ], "typeahead" => true },
        { "field" => "epic_id", "label" => "Epic", "bucket" => "fk", "operators" => %w[ is ], "typeahead" => true },
        { "field" => "hostname", "label" => "Hostname", "bucket" => "fk", "operators" => %w[ is ], "typeahead" => true },
        { "field" => "job_type", "label" => "Job type", "bucket" => "enum", "operators" => %w[ is_one_of ], "values" => JOB_TYPES },
        { "field" => "status", "label" => "Status", "bucket" => "enum", "operators" => %w[ is_one_of ], "values" => STATUSES.map { |status| { "value" => status, "label" => status.capitalize } } },
        { "field" => "window", "label" => "Time window", "bucket" => "date", "operators" => %w[ within_last between ] }
      ]
    end

    def self.from_params(params)
      new(Filters::QueryParam.decode(params[:q]))
    end

    def initialize(tree)
      @chips = top_level_chips(Filters::Ast.parse(tree))
    end

    def to_h
      Filters::Ast.serialize(Filters::Ast::AndNode.new(children: @chips))
    end

    def repository_id
      chip_value("repository_id")
    end

    def epic_id
      chip_value("epic_id")
    end

    def hostname
      chip_value("hostname")
    end

    def status
      Array(chip_value("status"))
    end

    def job_type
      Array(chip_value("job_type"))
    end

    # Never returns nil, even for a malformed chip (unparsable "between"
    # bound, unsupported within_last unit): MacroQuery's own DEFAULT_WINDOW
    # is 1 hour (the documented default for the separate bearer-token
    # API), so leaking a nil from/to through would silently reintroduce
    # the 1-hour window this default was written to replace.
    def from
      return now - DEFAULT_WINDOW unless window_chip

      if window_chip.op == "between"
        parse_time(Array(window_chip.value).first) || now - DEFAULT_WINDOW
      else
        duration_for(window_chip.value)&.ago || now - DEFAULT_WINDOW
      end
    end

    def to
      return now unless window_chip

      window_chip.op == "between" ? (parse_time(Array(window_chip.value).last) || now) : now
    end

    private

    def now
      @now ||= Time.current
    end

    def top_level_chips(node)
      case node
      when Filters::Ast::Chip then [ node ]
      when Filters::Ast::AndNode then node.children.select { |child| child.is_a?(Filters::Ast::Chip) }
      else []
      end
    end

    def chip_value(field)
      @chips.find { |chip| chip.field == field }&.value
    end

    def window_chip
      @chips.find { |chip| chip.field == "window" }
    end

    def parse_time(value)
      return nil if value.blank?

      case value
      when Time, DateTime, ActiveSupport::TimeWithZone then value
      when Date then value.in_time_zone
      else Time.zone.parse(value.to_s)
      end
    rescue ArgumentError
      nil
    end

    def duration_for(value)
      return nil unless value.is_a?(Hash)

      spec = value.transform_keys(&:to_s)
      per = Filters::Chips::DateColumn::UNITS[spec["unit"].to_s]
      return nil unless per

      per * (Integer(spec["n"], exception: false) || 0)
    end
  end
end
