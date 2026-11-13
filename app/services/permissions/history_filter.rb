module Permissions
  class HistoryFilter
    SCHEMA = [
      { "field" => "capability", "label" => "Capability or operation", "bucket" => "text", "operators" => %w[contains is] },
      { "field" => "outcome", "label" => "Outcome", "bucket" => "enum", "operators" => %w[is is_not is_one_of],
        "values" => %w[active approved cancelled claimed confirmed created denied dismissed exhausted expired failed invalidated
          issued non_actionable non_resumable pending rejected revoked succeeded updated] },
      { "field" => "actor", "label" => "Agent or role", "bucket" => "text", "operators" => %w[contains is] },
      { "field" => "context", "label" => "Chat or job", "bucket" => "text", "operators" => %w[contains is] },
      { "field" => "occurred_at", "label" => "Date", "bucket" => "date",
        "operators" => %w[before after between within_last more_than_ago], "date_precision" => "datetime" }
    ].freeze

    def self.schema = SCHEMA

    def initialize(tree)
      @ast = Filters::Ast.parse(tree)
    end

    # Apply the same AST at the database boundary. History is a union of four
    # independently-owned tables, so each source supplies the SQL expressions
    # that represent its serialized fields. Filtering before the per-source
    # limit keeps selective searches complete without materializing the full
    # history in Ruby.
    def apply(relation, source:)
      relation.where(compile(@ast, source))
    end

    private

    def compile(node, source)
      case node
      when Filters::Ast::AndNode then combine(node.children, source, "AND", "1=1")
      when Filters::Ast::OrNode then combine(node.children, source, "OR", "1=0")
      when Filters::Ast::NotNode then "NOT (#{compile(node.child, source)})"
      when Filters::Ast::Chip then compile_chip(node, source)
      else "1=0"
      end
    end

    def combine(children, source, operator, empty)
      return empty if children.empty?

      children.map { |child| "(#{compile(child, source)})" }.join(" #{operator} ")
    end

    def compile_chip(chip, source)
      return compile_date(chip, source) if chip.field == "occurred_at"
      return request_item_chip(chip) if source == :request && chip.field.in?(%w[capability outcome])

      expressions = source_expressions(source).fetch(chip.field)
      expected = Array(chip.value).map(&:to_s)
      comparisons = expressions.product(expected).map { |expression, value| text_comparison(expression, value, chip.op) }
      matched = comparisons.any? ? comparisons.join(" OR ") : "1=0"
      chip.op == "is_not" ? "NOT (#{matched})" : "(#{matched})"
    end

    def request_item_chip(chip)
      columns = chip.field == "capability" ? %w[capability operation] : %w[state]
      expected = Array(chip.value).map(&:to_s)
      item_matches = columns.product(expected).map do |column, value|
        text_comparison("pending_action_items.#{column}", value, chip.op)
      end.join(" OR ")
      matches = [ "EXISTS (SELECT 1 FROM pending_action_items WHERE " \
        "pending_action_items.chat_pending_action_id = chat_pending_actions.id AND (#{item_matches}))" ]
      if chip.field == "outcome"
        matches.concat(expected.map { |value| text_comparison("chat_pending_actions.state", value, chip.op) })
      end
      matched = matches.join(" OR ")
      chip.op == "is_not" ? "NOT (#{matched})" : "(#{matched})"
    end

    def text_comparison(expression, value, operator)
      normalized = value.downcase
      if operator == "contains"
        pattern = "%#{ActiveRecord::Base.sanitize_sql_like(normalized, "!")}%"
        "LOWER(COALESCE(#{expression}, '')) LIKE #{quote(pattern)} ESCAPE '!'"
      else
        "LOWER(COALESCE(#{expression}, '')) = #{quote(normalized)}"
      end
    end

    def compile_date(chip, source)
      column = source_expressions(source).fetch("occurred_at").first
      case chip.op
      when "before" then "#{column} < #{quote(parse_time(chip.value))}"
      when "after" then "#{column} > #{quote(parse_time(chip.value))}"
      when "between"
        from, to = Array(chip.value).map { |value| parse_time(value) }
        "#{column} BETWEEN #{quote(from)} AND #{quote(to)}"
      when "within_last" then "#{column} >= #{quote(relative_time(chip.value))}"
      when "more_than_ago" then "#{column} < #{quote(relative_time(chip.value))}"
      else raise ArgumentError, "unsupported date operator: #{chip.op.inspect}"
      end
    end

    def parse_time(value)
      Time.zone.parse(value.to_s) || raise(ArgumentError, "invalid permission history date: #{value.inspect}")
    end

    def quote(value) = ActiveRecord::Base.connection.quote(value)

    def source_expressions(source)
      @source_expressions ||= {
        request: {
          "capability" => [ item_exists("capability"), item_exists("operation") ],
          "outcome" => [ "chat_pending_actions.state", item_exists("state") ],
          "actor" => [ "chat_pending_actions.requested_by", item_reference_exists("decision_principal"), item_reference_exists("resulting_authority"),
            item_user_label_exists("decision_principal"), item_user_label_exists("resulting_authority") ],
          "context" => [ "chat_pending_actions.origin_type", "chat_pending_actions.origin_id",
            polymorphic_context_label("chat_pending_actions", "origin"), occurrence_exists("origin_type"), occurrence_exists("origin_id"),
            occurrence_context_label("Job", "jobs", "issue_title"), occurrence_context_label("ChatSession", "chat_sessions", "title") ],
          "occurred_at" => [ "chat_pending_actions.created_at" ]
        },
        invocation: {
          "capability" => [ "pending_action_items.capability", "pending_action_items.operation" ],
          "outcome" => [ "authorized_invocations.state", "authorized_invocations.result_status" ],
          "actor" => [ "authorized_invocations.claimed_by_type", "authorized_invocations.claimed_by_id", polymorphic_user_label("authorized_invocations", "claimed_by") ],
          "context" => [ "chat_pending_actions.origin_type", "chat_pending_actions.origin_id", polymorphic_context_label("chat_pending_actions", "origin") ],
          "occurred_at" => [ "authorized_invocations.created_at" ]
        },
        rule: {
          "capability" => [ "permission_rules.capability", "permission_rules.operation" ],
          "outcome" => [ "permission_rule_audit_events.event_type" ],
          "actor" => [ "users.id", "users.email_address", "users.name" ],
          "context" => [],
          "occurred_at" => [ "permission_rule_audit_events.created_at" ]
        },
        lease: {
          "capability" => [ "permission_leases.capability", "permission_leases.operation" ],
          "outcome" => [ lease_state_sql ],
          "actor" => [ "permission_leases.subject_selector_type", user_label_exists("permission_leases.issued_by_user_id"), user_label_exists("permission_leases.revoked_by_user_id") ],
          "context" => [ "permission_leases.source_type", "permission_leases.source_id", "permission_leases.chat_session_id", "permission_leases.job_id",
            polymorphic_context_label("permission_leases", "source"), context_label("permission_leases.job_id", "jobs", "issue_title"),
            context_label("permission_leases.chat_session_id", "chat_sessions", "title") ],
          "occurred_at" => [ "permission_leases.created_at" ]
        }
      }.freeze
      @source_expressions.fetch(source)
    end

    def item_exists(column)
      "(SELECT #{column} FROM pending_action_items WHERE pending_action_items.chat_pending_action_id = chat_pending_actions.id LIMIT 1)"
    end

    def item_reference_exists(prefix)
      "(SELECT COALESCE(#{prefix}_type, #{prefix}_id) FROM pending_action_items WHERE pending_action_items.chat_pending_action_id = chat_pending_actions.id LIMIT 1)"
    end

    def item_user_label_exists(prefix)
      "(SELECT COALESCE(users.email_address, users.name) FROM pending_action_items " \
        "JOIN users ON #{prefix}_type = 'User' AND users.id = #{prefix}_id " \
        "WHERE pending_action_items.chat_pending_action_id = chat_pending_actions.id LIMIT 1)"
    end

    def occurrence_exists(column)
      "(SELECT #{column} FROM pending_action_occurrences WHERE pending_action_occurrences.chat_pending_action_id = chat_pending_actions.id LIMIT 1)"
    end

    def occurrence_context_label(type, table, label)
      "(SELECT #{table}.#{label} FROM pending_action_occurrences JOIN #{table} " \
        "ON pending_action_occurrences.origin_type = '#{type}' AND #{table}.id = pending_action_occurrences.origin_id " \
        "WHERE pending_action_occurrences.chat_pending_action_id = chat_pending_actions.id LIMIT 1)"
    end

    def polymorphic_context_label(table, prefix)
      job = "(SELECT jobs.issue_title FROM jobs WHERE #{table}.#{prefix}_type = 'Job' AND jobs.id = #{table}.#{prefix}_id LIMIT 1)"
      chat = "(SELECT chat_sessions.title FROM chat_sessions WHERE #{table}.#{prefix}_type = 'ChatSession' AND chat_sessions.id = #{table}.#{prefix}_id LIMIT 1)"
      "COALESCE(#{job}, #{chat})"
    end

    def context_label(id_column, table, label)
      "(SELECT #{table}.#{label} FROM #{table} WHERE #{table}.id = #{id_column} LIMIT 1)"
    end

    def polymorphic_user_label(table, prefix)
      "(SELECT COALESCE(users.email_address, users.name) FROM users WHERE #{table}.#{prefix}_type = 'User' AND users.id = #{table}.#{prefix}_id LIMIT 1)"
    end

    def user_label_exists(id_column)
      "(SELECT COALESCE(users.email_address, users.name) FROM users WHERE users.id = #{id_column} LIMIT 1)"
    end

    def lease_state_sql
      now = quote(Time.current)
      "CASE WHEN permission_leases.revoked_at IS NOT NULL THEN 'revoked' " \
        "WHEN permission_leases.expires_at IS NOT NULL AND permission_leases.expires_at <= #{now} THEN 'expired' " \
        "WHEN permission_leases.max_uses IS NOT NULL AND permission_leases.used_count >= permission_leases.max_uses THEN 'exhausted' ELSE 'active' END"
    end

    def relative_time(value)
      amount = value.to_h.fetch("n").to_i
      unit = value.to_h.fetch("unit").to_s
      raise ArgumentError, "unsupported relative date unit: #{unit.inspect}" unless unit.in?(%w[seconds minutes hours days weeks months years])

      amount.public_send(unit).ago
    end
  end
end
