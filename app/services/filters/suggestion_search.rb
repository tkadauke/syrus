module Filters
  class SuggestionSearch
    LIMIT = 8

    def self.call(user:, surface:, subject:, query:, active_tree: nil, limit: LIMIT)
      new(user:, surface:, subject:, query:, active_tree:, limit:).call
    end

    def initialize(user:, surface:, subject:, query:, active_tree: nil, limit: LIMIT)
      @user = user
      @surface = surface.to_s
      @subject = subject.to_s
      @query = query.to_s.strip
      @active_tree = active_tree
      @limit = limit.to_i.positive? ? limit.to_i : LIMIT
      @schema = Filters::Schema.for(subject: @subject.to_sym, user: user)
      validate_surface!
    end

    def call
      return [] if query.blank?

      candidates = frequent_suggestions + value_suggestions
      deduplicate(candidates)
        .sort_by { |candidate| [ -candidate.fetch(:score), candidate.fetch(:label).downcase ] }
        .first(limit)
        .map { |candidate| candidate.except(:score, :fingerprint) }
    end

    private

    attr_reader :user, :surface, :subject, :query, :active_tree, :limit, :schema

    def validate_surface!
      return if FilterUsage::SURFACES.include?(surface)

      raise ArgumentError, "unknown filter suggestion surface: #{surface}"
    end

    def frequent_suggestions
      pattern = "%#{ActiveRecord::Base.sanitize_sql_like(query.downcase)}%"
      FilterUsage
        .where(user: user, surface: surface, subject: subject)
        .where("LOWER(label) LIKE ?", pattern)
        .order(Arel.sql("use_count DESC, last_used_at DESC, id DESC"))
        .limit(limit * 2)
        .filter_map do |usage|
          node = normalized_node(usage.filter_node)
          next unless node

          candidate(
            id: "usage-#{usage.id}",
            label: usage.label,
            filter: node,
            source: "frequent",
            score: 1_000 + usage.use_count.to_i
          )
        end
    end

    def value_suggestions
      schema.flat_map do |meta|
        case meta.fetch("bucket")
        when "fk"
          fk_suggestions(meta)
        when "boolean"
          boolean_suggestions(meta)
        else
          static_value_suggestions(meta)
        end
      end
    end

    def fk_suggestions(meta)
      return [] unless meta["typeahead"]

      Filters::FkOptionsResolver
        .new(user: user)
        .resolve(field: meta.fetch("field"), q: query, limit: per_field_limit)
        .filter_map do |option|
          value_suggestion(meta:, option:, op: "is", score: exact_match?(option.fetch("label")) ? 850 : 700)
        end
    rescue Filters::FkOptionsResolver::UnknownField
      []
    end

    def static_value_suggestions(meta)
      return [] unless meta["values"].is_a?(Array)

      op = static_value_operator(meta)
      return [] unless op

      options_for(meta).filter_map do |option|
        next unless matches?(meta.fetch("label"), option.fetch("label"), option.fetch("value"))

        value = multi_value_operator?(op) ? [ option.fetch("value") ] : option.fetch("value")
        value_suggestion(meta:, option:, op:, value:, score: 500)
      end
    end

    def boolean_suggestions(meta)
      [
        { "op" => "is_true", "label" => "true" },
        { "op" => "is_false", "label" => "false" }
      ].filter_map do |option|
        next unless meta.fetch("operators").include?(option.fetch("op"))
        next unless matches?(meta.fetch("label"), option.fetch("label"))

        filter = { "field" => meta.fetch("field"), "op" => option.fetch("op"), "value" => nil }
        candidate(
          id: "value-#{fingerprint(filter)}",
          label: "#{meta.fetch("label")} #{humanize_op(option.fetch("op"))}",
          filter: filter,
          source: "value",
          score: 400
        )
      end
    end

    def value_suggestion(meta:, option:, op:, value: option.fetch("value"), score:)
      filter = { "field" => meta.fetch("field"), "op" => op, "value" => value }
      candidate(
        id: "value-#{fingerprint(filter)}",
        label: "#{meta.fetch("label")} #{humanize_op(op)} #{option.fetch("label")}",
        filter: filter,
        source: "value",
        score: score
      )
    end

    def candidate(id:, label:, filter:, source:, score:)
      node = normalized_node(filter)
      return nil unless node

      fingerprint = fingerprint(node)
      return nil if active_fingerprints.include?(fingerprint)

      {
        id: id,
        label: label,
        filter: node,
        source: source,
        score: score,
        fingerprint: fingerprint
      }
    end

    def deduplicate(candidates)
      by_fingerprint = candidates.compact.each_with_object({}) do |candidate, acc|
        fp = candidate.fetch(:fingerprint)
        current = acc[fp]
        acc[fp] = candidate if current.nil? || candidate.fetch(:score) > current.fetch(:score)
      end.values

      by_fingerprint.each_with_object({}) do |candidate, acc|
        key = candidate.fetch(:label).downcase
        current = acc[key]
        acc[key] = candidate if current.nil? || candidate.fetch(:score) > current.fetch(:score)
      end.values
    end

    def active_fingerprints
      @active_fingerprints ||= top_level_nodes(active_tree).filter_map do |node|
        normalized = normalized_node(node)
        fingerprint(normalized) if normalized
      end
    end

    def top_level_nodes(tree)
      hash = normalize_hash(tree)
      return [] unless hash
      return hash.fetch("and").filter_map { |child| normalize_hash(child) } if hash["and"].is_a?(Array)

      [ hash ]
    end

    def normalized_node(node)
      Filters::Ast.serialize(Filters::Ast.parse(normalize_hash(node)))
    rescue ArgumentError
      nil
    end

    def fingerprint(node)
      Digest::SHA256.hexdigest(JSON.generate(canonical_value(node)))
    end

    def canonical_value(value)
      case value
      when Hash
        value.transform_keys(&:to_s).sort.to_h { |key, child| [ key, canonical_value(child) ] }
      when Array
        value.map { |child| canonical_value(child) }
      else
        value
      end
    end

    def options_for(meta)
      Array(meta["values"]).map do |option|
        option.is_a?(Hash) ? option.transform_keys(&:to_s) : { "value" => option, "label" => Filters::Schema.humanize_value(option) }
      end
    end

    def static_value_operator(meta)
      operators = meta.fetch("operators")
      return "is" if operators.include?("is")
      return "contains_any" if operators.include?("contains_any")

      nil
    end

    def multi_value_operator?(op)
      %w[is_one_of is_none_of contains_any contains_all contains_none].include?(op)
    end

    def per_field_limit
      [ limit, 5 ].min
    end

    def matches?(*values)
      values.any? { |value| value.to_s.downcase.include?(query.downcase) }
    end

    def exact_match?(value)
      value.to_s.downcase == query.downcase
    end

    def humanize_op(op)
      op.to_s.tr("_", " ")
    end

    def normalize_hash(value)
      return nil unless value.is_a?(Hash)

      value.deep_stringify_keys
    end
  end
end
