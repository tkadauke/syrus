module Repositories
  # Repository index filtering. Repository health, open-jobs, and
  # job-activity are computed values (not plain columns queryable via
  # Filters::Compiler), and the repository list per instance is small, so
  # this filters an already-loaded Array of Repository records in Ruby
  # rather than compiling the AST into an ActiveRecord scope the way
  # Filters::Compiler-backed subjects do. It still uses Filters::Ast for
  # tree parsing/serialization -- and Filters::BaseFilter for the shared
  # `q=<base64-json>` chip-bar wire format -- so SmartFolder#filter and the
  # repository index's FilterBar stay wired the same way every other
  # FilterBar-backed subject is.
  class Filter
    include Filters::BaseFilter

    # Flat URL-param keys the legacy dropdown filter bar used to emit.
    # Each is translated to one or more AST chips by `build_tree_from_url_params`.
    # `q` is deliberately excluded -- Filters::BaseFilter.from_params decodes
    # it separately as the chip-bar's full AST tree, not a legacy param.
    LEGACY_URL_KEYS = %w[ slug search github_owner health agent_provider has_open_jobs archived ].freeze
    UNITS = { "minutes" => 1.minute, "hours" => 1.hour, "days" => 1.day, "weeks" => 1.week, "months" => 1.month }.freeze

    def self.build_tree_from_url_params(params)
      permitted = params.respond_to?(:permit) ? params.permit(*LEGACY_URL_KEYS).to_h : params.to_h
      permitted = permitted.transform_keys(&:to_s)

      chips = []
      term = permitted["slug"].presence || permitted["search"].presence
      chips << chip("slug", "contains", term) if term.present?
      chips << chip("github_owner", "is", permitted["github_owner"]) if permitted["github_owner"].present?
      chips << chip("health", "is", permitted["health"]) if permitted["health"].present?
      chips << chip("agent_provider", "is", permitted["agent_provider"]) if permitted["agent_provider"].present?
      chips << chip("has_open_jobs", "is", true) if boolean?(permitted["has_open_jobs"])
      chips << chip("archived", "is", true) if boolean?(permitted["archived"])

      { "and" => chips }
    end

    def self.boolean?(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end

    # `open_jobs_counts`/`last_job_activity_by_id` are the same
    # id => value hashes the repository index controller already preloads
    # to avoid N+1 queries; chips that need them (has_open_jobs,
    # last_job_activity_at) read from these instead of querying per-repo.
    def apply(repositories, open_jobs_counts: {}, last_job_activity_by_id: {})
      context = { open_jobs_counts: open_jobs_counts, last_job_activity_by_id: last_job_activity_by_id }
      repositories.select { |repository| node_matches?(@ast, repository, context) }
    end

    private

    # Evaluates the AND/OR/NOT tree structure directly (rather than
    # flattening every chip and AND-ing them together) so an OR group or a
    # NOT wrapper added through the chip bar behaves the way FilterBar's UI
    # promises, not just simple field=value narrowing.
    def node_matches?(node, repository, context)
      case node
      when Filters::Ast::Chip then chip_matches?(node, repository, context)
      when Filters::Ast::AndNode then node.children.all? { |child| node_matches?(child, repository, context) }
      when Filters::Ast::OrNode then node.children.any? { |child| node_matches?(child, repository, context) }
      when Filters::Ast::NotNode then !node_matches?(node.child, repository, context)
      else true
      end
    end

    def chip_matches?(chip, repository, context)
      case chip.field
      when "slug" then string_matches?(repository.slug, chip)
      when "github_owner" then enum_matches?(repository.owner, chip)
      when "health" then enum_matches?(repository.main_health, chip)
      when "agent_provider" then enum_matches?(repository.agent_provider.to_s, chip)
      when "has_open_jobs" then boolean_matches?(context[:open_jobs_counts].fetch(repository.id, 0).positive?, chip)
      when "archived" then boolean_matches?(repository.archived?, chip)
      when "last_job_activity_at" then activity_matches?(repository, chip, context[:last_job_activity_by_id])
      else true
      end
    end

    def string_matches?(actual, chip)
      haystack = actual.to_s.downcase
      value = chip.value.to_s.downcase
      case chip.op
      when "contains"            then haystack.include?(value)
      when "does_not_contain"    then !haystack.include?(value)
      when "starts_with"         then haystack.start_with?(value)
      when "does_not_start_with" then !haystack.start_with?(value)
      when "ends_with"           then haystack.end_with?(value)
      when "does_not_end_with"   then !haystack.end_with?(value)
      when "equals"              then haystack == value
      when "not_equals"          then haystack != value
      when "is_set"              then haystack.present?
      when "is_unset"            then haystack.blank?
      else true
      end
    end

    def enum_matches?(actual, chip)
      normalized = actual.to_s.downcase
      values = Array(chip.value).map { |v| v.to_s.downcase }
      case chip.op
      when "is", "is_one_of"   then values.include?(normalized)
      when "is_not", "is_none_of" then !values.include?(normalized)
      when "is_set"             then normalized.present?
      when "is_unset"           then normalized.blank?
      else true
      end
    end

    def boolean_matches?(actual, chip)
      case chip.op
      when "is_true"  then actual
      when "is_false" then !actual
      when "is"        then actual == self.class.boolean?(chip.value)
      when "is_not"    then actual != self.class.boolean?(chip.value)
      else true
      end
    end

    def activity_matches?(repository, chip, last_job_activity_by_id)
      return true unless chip.op == "within_last"

      cutoff = duration_for(chip.value).ago
      (activity_at = last_job_activity_by_id[repository.id]) && activity_at >= cutoff
    end

    def duration_for(value)
      spec = value.is_a?(Hash) ? value : {}
      n = Integer(spec["n"] || spec[:n] || 0)
      unit = (spec["unit"] || spec[:unit]).to_s
      per = UNITS.fetch(unit) { raise ArgumentError, "unknown duration unit: #{unit.inspect}" }
      per * n
    end
  end
end
