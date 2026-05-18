module Filters
  # Serializes Filters::Registry into a JSON-friendly array that
  # describes every chip type's bucket, operator vocabulary, value
  # set (when statically known), and human label. The chip-bar UI
  # consumes this to render add-filter menus and per-chip editors.
  module Schema
    module_function

    # Returns an Array<Hash> with one entry per registered chip,
    # ordered by Registry::CHIPS' declaration order so the add-filter
    # menu shows fields in the logical grouping the registry uses.
    def for(subject: :job, user: nil)
      Registry.fields(subject: subject).map { |field| chip_for(field, user: user, subject: subject) }
    end

    def for_user(user, subject: :job)
      self.for(subject: subject, user: user)
    end

    def chip_for(field, user: nil, subject: :job)
      chip = Registry.find(field, subject: subject)
      meta = {
        "field"     => field,
        "label"     => chip.label,
        "bucket"    => chip.bucket.to_s,
        "operators" => chip.operators.map(&:to_s)
      }
      if chip.respond_to?(:typeahead) && chip.typeahead
        meta["typeahead"] = true
      else
        meta["values"] = humanize_values(dynamic_values(chip, user) || chip.values)
      end
      meta["expansions"] = chip.expansions if chip.respond_to?(:expansions)
      meta
    end

    # Take an array of static enum values (strings) or pre-labeled
    # hashes and emit a uniform `[{value, label}]` shape with the
    # label run through `humanize_value` so "pr_merged" displays as
    # "PR merged" and "external_pr_merged" displays as "External PR
    # merged". Pre-labeled entries (dynamic_values from FK chips) are
    # passed through untouched.
    def humanize_values(values)
      return values unless values.is_a?(Array)
      values.map do |v|
        case v
        when Hash         then v
        when String, Symbol then { "value" => v.to_s, "label" => humanize_value(v) }
        else v
        end
      end
    end

    # Sentence-case humanizer with acronym handling. Designed for
    # short enum values like "pr_merged", "ci_failure",
    # "awaiting_approval" — first word capitalized, rest lowercase,
    # except known acronyms which stay uppercase wherever they fall.
    ACRONYMS = %w[PR CI AI ID URL API MCP].freeze

    def humanize_value(value)
      parts = value.to_s.split(/[_\-]/)
      parts.map.with_index do |word, i|
        upper = word.upcase
        if ACRONYMS.include?(upper)
          upper
        elsif i.zero?
          word.capitalize
        else
          word.downcase
        end
      end.join(" ")
    end

    # FK chips (repository_id, epic_id, parent_job_id) need
    # per-user value lists. The schema embeds them inline so the
    # chip-bar UI doesn't need an extra autocomplete round-trip
    # for the small data sets a single user owns.
    def dynamic_values(chip, user)
      return nil unless user

      return nil unless Filters::FkOptionsResolver::FIELDS.include?(chip.filter_name)

      limit = %w[ parent_job_id job_id ].include?(chip.filter_name) ? 200 : nil
      Filters::FkOptionsResolver.new(user: user).resolve(field: chip.filter_name, limit:)
    rescue NoMethodError
      # If the user model doesn't expose one of these associations
      # (test fixtures, partial migrations, etc.) — fall back to the
      # static `values` list. The chip stays usable as a free input.
      nil
    end

    def epic_label(epic)
      number = epic.respond_to?(:number) ? epic.number : epic.id
      "EPIC-#{number} #{epic.title}".strip
    end
  end
end
