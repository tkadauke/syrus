module Repositories
  # Repository index filtering. Repository health, open-jobs, and
  # job-activity are computed values (not plain columns queryable via
  # Filters::Compiler), and the repository list per instance is small, so
  # this filters an already-loaded Array of Repository records in Ruby
  # rather than compiling the AST into an ActiveRecord scope the way
  # Filters::Compiler-backed subjects do. It still uses Filters::Ast for
  # tree parsing/serialization so SmartFolder#filter stays a normal,
  # generically-shaped filter tree.
  class Filter
    LEGACY_URL_KEYS = %w[ slug q search github_owner health agent_provider has_open_jobs archived ].freeze
    UNITS = { "minutes" => 1.minute, "hours" => 1.hour, "days" => 1.day, "weeks" => 1.week, "months" => 1.month }.freeze

    def initialize(tree)
      @ast = Filters::Ast.parse(tree)
    end

    def self.from_tree(tree, user: nil)
      new(tree)
    end

    def self.from_params(params, smart_folder: nil, user: nil)
      folder_tree = smart_folder&.filter.presence
      url_tree = tree_from_params(params)
      tree = [ folder_tree, url_tree ].compact.reduce { |acc, next_tree| merge_and(acc, next_tree) }

      new(tree || Filters::Ast.serialize(Filters::Ast::EMPTY))
    end

    # Whether `smart_folder`'s saved filter should still act as the floor for
    # a `from_params` call built from these params -- mirrors
    # Filters::BaseFilter#smart_folder_floor for subjects that don't compile
    # to an ActiveRecord scope.
    def self.smart_folder_floor(params, smart_folder, user: nil)
      return nil if smart_folder.nil?

      from_params(params, smart_folder: nil, user: user).active? ? nil : smart_folder
    end

    def self.tree_from_params(params)
      permitted = params.respond_to?(:permit) ? params.permit(*LEGACY_URL_KEYS).to_h : params.to_h
      permitted = permitted.transform_keys(&:to_s)

      chips = []
      term = permitted["slug"].presence || permitted["q"].presence || permitted["search"].presence
      chips << { "field" => "slug", "op" => "contains", "value" => term } if term.present?
      chips << { "field" => "github_owner", "op" => "is", "value" => permitted["github_owner"] } if permitted["github_owner"].present?
      chips << { "field" => "health", "op" => "is", "value" => permitted["health"] } if permitted["health"].present?
      chips << { "field" => "agent_provider", "op" => "is", "value" => permitted["agent_provider"] } if permitted["agent_provider"].present?
      chips << { "field" => "has_open_jobs", "op" => "is", "value" => true } if boolean?(permitted["has_open_jobs"])
      chips << { "field" => "archived", "op" => "is", "value" => true } if boolean?(permitted["archived"])

      { "and" => chips }
    end

    def self.merge_and(left_tree, right_tree)
      children = [ left_tree, right_tree ].flat_map do |tree|
        tree.is_a?(Hash) && tree["and"].is_a?(Array) ? tree["and"] : [ tree ]
      end
      { "and" => children }
    end

    def self.boolean?(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end

    def to_h
      Filters::Ast.serialize(@ast)
    end

    def active?
      chip_nodes.any?
    end

    # `open_jobs_counts`/`last_job_activity_by_id` are the same
    # id => value hashes the repository index controller already preloads
    # to avoid N+1 queries; chips that need them (has_open_jobs,
    # last_job_activity_at) read from these instead of querying per-repo.
    def apply(repositories, open_jobs_counts: {}, last_job_activity_by_id: {})
      chip_nodes.reduce(repositories) { |scope, chip| apply_chip(scope, chip, open_jobs_counts, last_job_activity_by_id) }
    end

    private

    def chip_nodes
      @chip_nodes ||= collect_chips(@ast)
    end

    def collect_chips(node, collected = [])
      case node
      when Filters::Ast::Chip
        collected << node
      when Filters::Ast::AndNode, Filters::Ast::OrNode
        node.children.each { |child| collect_chips(child, collected) }
      when Filters::Ast::NotNode
        collect_chips(node.child, collected)
      end
      collected
    end

    def apply_chip(repositories, chip, open_jobs_counts, last_job_activity_by_id)
      case chip.field
      when "slug"
        term = chip.value.to_s.downcase
        repositories.select { |repository| repository.slug.downcase.include?(term) }
      when "github_owner"
        values = Array(chip.value).map { |value| value.to_s.downcase }
        repositories.select { |repository| values.include?(repository.owner.downcase) }
      when "health"
        values = Array(chip.value).map(&:to_s)
        repositories.select { |repository| values.include?(repository.main_health) }
      when "agent_provider"
        values = Array(chip.value).map(&:to_s)
        repositories.select { |repository| values.include?(repository.agent_provider.to_s) }
      when "has_open_jobs"
        desired = self.class.boolean?(chip.value)
        repositories.select { |repository| open_jobs_counts.fetch(repository.id, 0).positive? == desired }
      when "archived"
        desired = self.class.boolean?(chip.value)
        repositories.select { |repository| repository.archived? == desired }
      when "last_job_activity_at"
        apply_activity_chip(repositories, chip, last_job_activity_by_id)
      else
        repositories
      end
    end

    def apply_activity_chip(repositories, chip, last_job_activity_by_id)
      return repositories unless chip.op == "within_last"

      cutoff = duration_for(chip.value).ago
      repositories.select { |repository| (activity_at = last_job_activity_by_id[repository.id]) && activity_at >= cutoff }
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
