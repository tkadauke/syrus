require "rails_helper"
require "json"

RSpec.describe "Frontend locale keys", type: :unit do
  REVIEWED_SETTINGS_SCOPES = %w[
    connected_platforms
    input_sources
    linear_source
    account_settings
    scheduled_tasks
    cron_templates
    credential_cards
    configure_agent
  ].freeze
  INTENTIONAL_SETTINGS_ENGLISH_MATCHES = {
    "de" => {
      "connected_platforms.platforms.telegram" => "product name",
      "connected_platforms.platforms.slack" => "product name",
      "linear_source.section_heading" => "product name",
      "linear_source.api_key_placeholder" => "literal credential prefix",
      "linear_source.team_label" => "shared German UI term",
      "linear_source.label_filter_placeholder" => "shared German UI term",
      "account_settings.agent_provider_see_also_suffix" => "punctuation-only fragment",
      "account_settings.codex_chatgpt_login" => "product names and code filename",
      "account_settings.lang_deutsch" => "language endonym",
      "account_settings.passkeys_heading" => "established technical term",
      "scheduled_tasks.name" => "shared German UI term",
      "scheduled_tasks.col_repository" => "approved domain noun",
      "scheduled_tasks.task_source_skill" => "product terminology",
      "scheduled_tasks.skill_heading" => "product terminology",
      "scheduled_tasks.prompt_heading" => "product terminology",
      "scheduled_tasks.col_job" => "approved domain noun",
      "scheduled_tasks.col_pr" => "abbreviation",
      "scheduled_tasks.field_repository" => "approved domain noun",
      "cron_templates.col_name" => "shared German UI term",
      "cron_templates.applied_tasks_col_repo" => "approved domain noun",
      "cron_templates.section_prompt" => "product terminology",
      "cron_templates.section_skill" => "product terminology",
      "cron_templates.field_name" => "shared German UI term",
      "cron_templates.field_prompt" => "product terminology",
      "cron_templates.task_source_prompt" => "product terminology",
      "cron_templates.task_source_skill" => "product terminology",
      "credential_cards.github_title" => "product name",
      "credential_cards.claude_title" => "product name",
      "credential_cards.codex_title" => "product name",
      "credential_cards.muse_title" => "product name",
      "credential_cards.gemini_title" => "product name",
      "credential_cards.agy_title" => "product name",
      "credential_cards.chat_provider_see_also_suffix" => "punctuation-only fragment",
      "credential_cards.codex_auth_json_label" => "product names and code filename",
      "configure_agent.tab_claude" => "product name",
      "configure_agent.tab_codex" => "product name",
      "configure_agent.tab_agy" => "product name",
      "configure_agent.tab_muse" => "product name"
    },
    "la" => {
      "connected_platforms.platforms.telegram" => "product name",
      "connected_platforms.platforms.slack" => "product name",
      "linear_source.section_heading" => "product name",
      "linear_source.api_key_placeholder" => "literal credential prefix",
      "account_settings.agent_provider_see_also_suffix" => "punctuation-only fragment",
      "account_settings.codex_chatgpt_login" => "product names and code filename",
      "scheduled_tasks.col_pr" => "abbreviation",
      "cron_templates.col_status" => "shared Latin UI term",
      "credential_cards.github_title" => "product name",
      "credential_cards.claude_title" => "product name",
      "credential_cards.codex_title" => "product name",
      "credential_cards.muse_title" => "product name",
      "credential_cards.gemini_title" => "product name",
      "credential_cards.agy_title" => "product name",
      "credential_cards.chat_provider_see_also_suffix" => "punctuation-only fragment",
      "credential_cards.codex_auth_json_label" => "product names and code filename",
      "configure_agent.tab_claude" => "product name",
      "configure_agent.tab_codex" => "product name",
      "configure_agent.tab_agy" => "product name",
      "configure_agent.tab_muse" => "product name"
    }
  }.freeze

  REFERENCED_CORE_KEYS = {
    "admin" => %w[
      page_title_work_units
      page_title_backend_exceptions
      nav_work_units
      nav_backend_exceptions
      work_units.heading
      work_units.aria
      work_units.description
      work_units.loading
      work_units.error_load
      work_units.refresh
      work_units.refreshing
      work_units.show_user_debug
      work_units.hide_user_debug
      backend_exceptions.heading
      backend_exceptions.aria
      backend_exceptions.loading
      backend_exceptions.error_load
      backend_exceptions.refresh
      backend_exceptions.refreshing
      features.slugs.browser_error_auto_reports.name
      mcp_tool_usage.clear_filters
      mcp_tool_usage.search
    ],
    "common" => %w[
      status.skipped
      blocked_reasons.pr_checks_failing_base_unknown
      blocked_reasons.pr_checks_failing_base_stale
    ],
    "jobs" => %w[
      recheck_pr_checks
      retry_with_agent
      retry_with_agent_feedback
      section_workflows_loading
      section_workflows_load_error
      pr_checks_head_sha
      pr_checks_payload_base_sha
      pr_checks_override_once
      pr_checks_override_confirm
      pr_checks_override_reason
    ],
    "settings" => %w[
      repository.needs_triage_showing_limited
      repository.col_issue
      repository_form.insight_scheduling_badge_on
      repository_form.insight_scheduling_badge_off
    ]
  }.freeze

  def supported_locales
    %w[en de la]
  end

  def flatten_json(value, prefix = [])
    return { prefix.join(".") => value } unless value.is_a?(Hash)

    value.each_with_object({}) do |(key, child), leaves|
      leaves.merge!(flatten_json(child, prefix + [ key.to_s ]))
    end
  end

  def locale_namespaces(root)
    supported_locales.index_with do |locale|
      Dir.glob(root.join(locale, "*.json")).sort.to_h do |path|
        [ File.basename(path, ".json"), JSON.parse(File.read(path)) ]
      end
    end
  end

  def parity_failures(label, namespaces_by_locale)
    english_namespaces = namespaces_by_locale.fetch("en")

    supported_locales.filter_map do |locale|
      namespaces = namespaces_by_locale.fetch(locale)
      missing_files = english_namespaces.keys.sort - namespaces.keys.sort
      extra_files = namespaces.keys.sort - english_namespaces.keys.sort
      key_failures = (english_namespaces.keys & namespaces.keys).filter_map do |namespace|
        expected = flatten_json(english_namespaces.fetch(namespace)).keys.sort
        actual = flatten_json(namespaces.fetch(namespace)).keys.sort
        missing = expected - actual
        extra = actual - expected
        next if missing.empty? && extra.empty?

        [
          "#{namespace}:",
          ("    missing: #{missing.join(', ')}" if missing.any?),
          ("    extra: #{extra.join(', ')}" if extra.any?)
        ].compact.join("\n")
      end
      next if missing_files.empty? && extra_files.empty? && key_failures.empty?

      [
        "#{label} #{locale}:",
        ("  missing namespace files: #{missing_files.join(', ')}" if missing_files.any?),
        ("  extra namespace files: #{extra_files.join(', ')}" if extra_files.any?),
        key_failures.map { |failure| "  #{failure}" }
      ].flatten.compact.join("\n")
    end
  end

  def dig_key(tree, key)
    key.split(".").reduce(tree) do |value, part|
      return nil unless value.is_a?(Hash)

      value[part]
    end
  end

  def static_core_key_references
    Dir.glob(Rails.root.join("app/frontend/**/*.{ts,tsx}")).sort.flat_map do |path|
      source = File.read(path)
      references = source.scan(/\bi18n\.t\(["']([a-z_]+):([^"']+)["']\s*[,)]/).map { |namespace, key| [ path, namespace, key ] }
      namespaces = source.scan(/\buseT\(["']([a-z_]+)["']\)/).flatten.uniq
      if namespaces.one?
        references.concat(source.scan(/(?<![.\w])t\(["']([^"']+)["']\s*[,)]/).flatten.map do |key|
          explicit_namespace, explicit_key = key.split(":", 2)
          explicit_key ? [ path, explicit_namespace, explicit_key ] : [ path, namespaces.first, key ]
        end)
      end
      references
    end.uniq
  end

  def plural_pair_failures(namespaces)
    namespaces.flat_map do |namespace, tree|
      keys = flatten_json(tree).keys
      plural_bases = keys.filter_map do |key|
        key.delete_suffix("_one") if key.end_with?("_one")
      end | keys.filter_map do |key|
        key.delete_suffix("_other") if key.end_with?("_other")
      end

      plural_bases.sort.filter_map do |base|
        missing = %w[one other].reject { |suffix| keys.include?("#{base}_#{suffix}") }
        "#{namespace}.#{base} missing #{missing.join(' and ')}" if missing.any?
      end
    end
  end

  def interpolation_names(value)
    return [] unless value.is_a?(String)

    value.scan(/\{\{([^},]+)(?:,[^}]*)?\}\}/).flatten.sort
  end

  it "keeps core frontend JSON locale key trees identical" do
    root = Rails.root.join("app/frontend/i18n/locales")

    failures = parity_failures("core", locale_namespaces(root))

    expect(failures).to be_empty, failures.join("\n")
  end

  it "resolves core locale keys referenced by admin work units, exceptions, jobs, and repository triage UI" do
    root = Rails.root.join("app/frontend/i18n/locales")
    namespaces = locale_namespaces(root)
    failures = supported_locales.flat_map do |locale|
      REFERENCED_CORE_KEYS.flat_map do |namespace, keys|
        tree = namespaces.fetch(locale).fetch(namespace)

        keys.filter_map do |key|
          value = dig_key(tree, key)
          next if value.is_a?(String) && value.present?

          "#{locale}/#{namespace}.#{key}"
        end
      end
    end

    expect(failures).to be_empty, "Missing or blank referenced frontend locale keys:\n#{failures.join("\n")}"
  end

  it "resolves statically referenced core locale keys" do
    english = locale_namespaces(Rails.root.join("app/frontend/i18n/locales")).fetch("en")
    failures = static_core_key_references.filter_map do |path, namespace, key|
      next unless english.key?(namespace)
      tree = english.fetch(namespace)
      next if dig_key(tree, key).present?
      next if dig_key(tree, "#{key}_one").present? && dig_key(tree, "#{key}_other").present?

      "#{path.delete_prefix("#{Rails.root}/")}: #{namespace}.#{key}"
    end

    expect(failures).to be_empty, "Missing statically referenced core locale keys:\n#{failures.join("\n")}"
  end

  it "keeps pluralized core locale keys in one/other pairs" do
    english = locale_namespaces(Rails.root.join("app/frontend/i18n/locales")).fetch("en")
    failures = plural_pair_failures(english)

    expect(failures).to be_empty, "Incomplete core plural key pairs:\n#{failures.join("\n")}"
  end

  it "preserves approved German copy for the confirmed locale defects" do
    locales = locale_namespaces(Rails.root.join("app/frontend/i18n/locales"))
    german = locales.fetch("de")

    expect(dig_key(german.fetch("nav"), "smart_folder_names.repositories_recent")).to eq("Kürzlich")
    expect(dig_key(german.fetch("nav"), "smart_folder_names.admin_queue_runs")).to eq("Läufe")
    expect(dig_key(german.fetch("nav"), "smart_folder_names.admin_queue_low_priority_maintenance")).to eq("Niedrige Priorität")
    expect(dig_key(german.fetch("nav"), "smart_folder.names.admin_queue_low_priority_maintenance")).to eq("Niedrige Priorität")
    expect(dig_key(german.fetch("admin"), "mcp_tool_usage.card_gap_ranking_heading")).to eq("Custom-Card-Lückenranking")
    expect(dig_key(german.fetch("admin"), "mcp_tool_usage.card_gap_ranking_empty")).to include("Custom-Card-Lücken")

    %w[en de la].each do |locale|
      admin = locales.fetch(locale).fetch("admin")
      expect(interpolation_names(dig_key(admin, "console.restart_confirm_with_runs_one"))).to be_empty
      expect(interpolation_names(dig_key(admin, "console.restart_confirm_with_runs_other"))).to eq([ "count" ])
    end
  end

  it "translates the reviewed settings scopes except for documented intentional matches" do
    settings = locale_namespaces(Rails.root.join("app/frontend/i18n/locales")).transform_values { |locales| locales.fetch("settings") }
    english = settings.fetch("en")

    INTENTIONAL_SETTINGS_ENGLISH_MATCHES.each do |locale, documented_matches|
      actual_matches = REVIEWED_SETTINGS_SCOPES.flat_map do |scope|
        english_leaves = flatten_json(english.fetch(scope), [ scope ])
        localized_leaves = flatten_json(settings.fetch(locale).fetch(scope), [ scope ])
        english_leaves.filter_map { |key, value| key if localized_leaves.fetch(key) == value }
      end

      expect(actual_matches.sort).to eq(documented_matches.keys.sort)
      expect(documented_matches.values).to all(be_present)
    end
  end

  it "preserves placeholders, plural pairs, and approved terminology in the reviewed settings copy" do
    settings = locale_namespaces(Rails.root.join("app/frontend/i18n/locales")).transform_values { |locales| locales.fetch("settings") }
    english = settings.fetch("en")

    %w[de la].each do |locale|
      REVIEWED_SETTINGS_SCOPES.each do |scope|
        english_leaves = flatten_json(english.fetch(scope), [ scope ])
        localized_leaves = flatten_json(settings.fetch(locale).fetch(scope), [ scope ])

        english_leaves.each do |key, value|
          expect(interpolation_names(localized_leaves.fetch(key))).to eq(interpolation_names(value)), "#{locale}.settings.#{key} changed placeholders"
        end
      end
    end

    german = settings.fetch("de")
    german_copy = REVIEWED_SETTINGS_SCOPES.flat_map { |scope| flatten_json(german.fetch(scope)).values }.join("\n")
    expect(german_copy).not_to match(/\b(?:Sie|Ihnen|Ihr\p{L}*)\b/)
    expect(dig_key(german, "linear_source.section_description")).to include("Syrus-Jobs")
    expect(dig_key(german, "input_sources.issues_ingested_one")).to eq("{{count}} Issue aufgenommen")
    expect(dig_key(german, "input_sources.issues_ingested_other")).to eq("{{count}} Issues aufgenommen")
    expect(dig_key(german, "account_settings.provider_availability_desc")).to include("Jobs dieses Providers")
    expect(dig_key(german, "scheduled_tasks.schedule_placeholder")).to eq("Jeden Montag um 09:00 Uhr")
    expect(dig_key(german, "configure_agent.exchange_error")).to eq(
      "Das von Claude zurückgegebene Token hat nicht funktioniert. Versuche es erneut."
    )

    latin = settings.fetch("la")
    expect(dig_key(latin, "input_sources.section_description")).to include("Repository")
    expect(dig_key(latin, "input_sources.polling_enabled_label")).to include("Polling")
    expect(dig_key(latin, "input_sources.issues_ingested_one")).to include("Issue")
    expect(dig_key(latin, "input_sources.issues_ingested_other")).to include("Issues")
    expect(dig_key(latin, "linear_source.section_description")).to eq(
      "Sonat gregem Linearem ad quaestiones apertas et officia Syri ex eis creat."
    )
    expect(dig_key(latin, "account_settings.provider_availability_desc")).to include("Job huius praebitoris")
    expect(dig_key(latin, "scheduled_tasks.schedule_placeholder")).to eq("Omni die Lunae hora 09:00")
    expect(dig_key(latin, "credential_cards.muse_description")).to include("cursibus operum")
  end

  it "detects either missing half of a plural pair" do
    expect(plural_pair_failures("chat" => { "items_one" => "one" })).to eq([ "chat.items missing other" ])
    expect(plural_pair_failures("chat" => { "items_other" => "many" })).to eq([ "chat.items missing one" ])
  end

  it "keeps plugin frontend JSON locale key trees identical" do
    failures = Dir.glob(Rails.root.join("plugins/*/app/frontend/i18n/locales")).sort.flat_map do |root_path|
      root = Pathname(root_path)
      plugin_name = root.each_filename.to_a.fetch(1)

      parity_failures("plugin #{plugin_name}", locale_namespaces(root))
    end

    expect(failures).to be_empty, failures.join("\n")
  end
end
