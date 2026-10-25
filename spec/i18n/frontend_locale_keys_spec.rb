require "rails_helper"
require "json"

RSpec.describe "Frontend locale keys", type: :unit do
  REVIEWED_SETTINGS_SCOPES = %w[
    themes
    profile
    design_system
    personal_documents
    target_graph
    repositories
    repository
    delivery
    repository_documents
    repository_memberships
    tags
    github_token
    github_app_panel
    add_repository
    repository_form
    provider_routing
    notifications
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
      "themes.name" => "shared German UI term",
      "themes.token_label" => "placeholder-only value",
      "themes.token_groups.status" => "shared German UI term",
      "profile.epics" => "approved domain noun",
      "profile.jobs" => "approved domain noun",
      "design_system.semantic.badge" => "release-stage label",
      "personal_documents.col_content_cache_state" => "established technical term",
      "target_graph.workflow" => "approved domain noun with placeholder",
      "repositories.col_repository" => "approved domain noun",
      "repositories.col_agent" => "approved domain noun",
      "repository.agent_prefix" => "approved domain noun",
      "repository.cognitive_blind" => "same word in German",
      "repository.cognitive_state_blind" => "same word in German",
      "repository.cognitive_chip_blind" => "same word in German",
      "repository.col_job" => "approved domain noun",
      "repository.col_issue" => "approved domain noun",
      "repository.pr_number" => "abbreviation with placeholder",
      "repository.health_ci" => "abbreviation",
      "repository.health_col_sha" => "established technical term",
      "repository.health_col_ci" => "abbreviation",
      "repository.health_source_ci_poll" => "abbreviation",
      "repository.health_source_concern_quorum" => "shared German technical term",
      "repository.aria_repository" => "approved domain noun",
      "repository.flaky_col_test" => "shared German technical term",
      "repository.flaky_col_suite" => "established technical term",
      "repository.syrus_yml_status" => "shared German UI term",
      "repository.syrus_yml_merge_train_rung_restart" => "configuration token",
      "repository.syrus_yml_merge_train_rung_keep_assembly" => "configuration token",
      "repository.syrus_yml_merge_train_rung_keep_fixes" => "configuration token",
      "repository.syrus_yml_merge_train_yaml" => "code filename",
      "delivery.col_branch" => "established Git technical term",
      "delivery.col_job" => "approved domain noun",
      "delivery.col_refs" => "abbreviation",
      "delivery.col_pr" => "abbreviation",
      "repository_documents.placeholder_optional" => "same word in German",
      "repository_memberships.role_admin" => "abbreviated role name",
      "repository_memberships.email_placeholder" => "example address",
      "tags.field_name" => "shared German UI term",
      "tags.col_jobs" => "approved domain noun",
      "github_token.step_app_label" => "product name",
      "add_repository.field_repository" => "approved domain noun",
      "provider_routing.trigger_step" => "product terminology with placeholder",
      "provider_routing.trigger_chat_role" => "product terminology with placeholder",
      "provider_routing.workflow_condition_pill" => "approved domain noun with placeholder",
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
      "themes.token_label" => "placeholder-only value",
      "themes.token_groups.status" => "valid Latin noun",
      "design_system.semantic.badge" => "release-stage label",
      "personal_documents.col_content_cache_state" => "established technical term",
      "repository.pr_number" => "abbreviation with placeholder",
      "repository.health_ci" => "abbreviation",
      "repository.health_col_ci" => "abbreviation",
      "repository.health_source_ci_poll" => "abbreviation",
      "repository.health_source_concern_quorum" => "Latin technical term",
      "repository.syrus_yml_status" => "valid Latin noun",
      "repository.syrus_yml_merge_train_rung_restart" => "configuration token",
      "repository.syrus_yml_merge_train_rung_keep_assembly" => "configuration token",
      "repository.syrus_yml_merge_train_rung_keep_fixes" => "configuration token",
      "repository.syrus_yml_merge_train_yaml" => "code filename",
      "delivery.col_pr" => "abbreviation",
      "repository_memberships.role_admin" => "abbreviated role name",
      "tags.field_color" => "valid Latin noun",
      "tags.col_color" => "valid Latin noun",
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

  INTENTIONAL_ADMIN_ENGLISH_MATCHES = {
    "de" => {
      "approved German domain term" => %w[
        work_units.col_jobs maintenance_tasks.col_landing stuck.link_workflow stuck.link_job
        processes.detail_workflow mcp_tool_usage.surface_workflow mcp_tool_usage.link_job
        mcp_tool_usage.link_workflow tool_cards.admin_overview.jobs tool_cards.admin_overview.job
        tool_cards.admin_overview.workflow
      ],
      "product, proper name, or protocol token" => %w[
        nav_github_app users.col_github users.info_github features.slugs.terminal.name
        settings.telegram_heading settings.discord_heading tool_cards.admin_overview.active_storage
        plugins.extension_points.agent_provider plugins.extension_points.mcp_tool_set
        plugins.extension_points.input_source
      ],
      "placeholder-only or value-only diagnostic" => %w[
        work_units.provider_availability_state browser_errors.revision_hint
        backend_exceptions.revision_hint teams.email_placeholder installations.sync_duration
        mcp_tool_usage.tool_placeholder mcp_tool_usage.server_placeholder
      ],
      "shared German word or established technical/diagnostic label" => %w[
        maintenance_tasks.filter_definition maintenance_tasks.col_status maintenance_tasks.col_level
        nav_teams nav_plugins browser_errors.id browser_errors.revision_scope browser_errors.stack
        backend_exceptions.revision_scope backend_exceptions.backtrace users.col_admin users.col_agent
        users.ok users.info_admin teams.heading teams.col_name teams.name_label operational_logs.revision_scope
        operational_logs.col_refs plugins.heading plugins.homepage plugins.version plugins.back_to_plugins
        plugins.col_tags installations.col_app_credential installations.col_pat_credential
        stuck.filter_status stuck.col_status console.runs_title queue.col_pid queue.col_threads
        queue.col_version queue.col_minute queue.metric_cpu queue.metric_disk queue.metric_io
        queue.metric_load processes.col_chat_session processes.col_host_pid processes.detail_pid_pgid
        mcp_tool_usage.surface_chat mcp_tool_usage.tool_label mcp_tool_usage.server_label
        mcp_tool_usage.status_label mcp_tool_usage.server_breakdown_heading
        mcp_tool_usage.startup_timing_col_phase mcp_tool_usage.startup_timing_col_p50
        mcp_tool_usage.startup_timing_col_p95 mcp_tool_usage.col_tool mcp_tool_usage.col_status
        mcp_tool_usage.col_links mcp_tool_usage.link_chat
      ]
    },
    "la" => {
      "Latin domain term pending competent review" => %w[
        maintenance_tasks.col_landing mcp_tool_usage.surface_workflow mcp_tool_usage.link_job
        mcp_tool_usage.link_workflow
      ],
      "product, proper name, or protocol token" => %w[
        users.col_github users.info_github settings.telegram_heading settings.discord_heading
        tool_cards.admin_overview.active_storage plugins.extension_points.agent_provider
        plugins.extension_points.mcp_tool_set plugins.extension_points.input_source
      ],
      "placeholder-only or value-only diagnostic" => %w[
        work_units.provider_availability_state browser_errors.revision_hint
        backend_exceptions.revision_hint teams.email_placeholder installations.sync_duration
        mcp_tool_usage.tool_placeholder mcp_tool_usage.server_placeholder
      ],
      "valid Latin word or established technical/diagnostic label" => %w[
        maintenance_tasks.col_status maintenance_tasks.col_error browser_errors.id
        browser_errors.col_error backend_exceptions.col_error backend_exceptions.backtrace
        users.col_gh_api users.status_prefix plugins.col_tags installations.col_pat_credential
        stuck.filter_status stuck.col_status console.col_operator console.runs_title queue.col_pid
        queue.metric_cpu queue.metric_io processes.detail_pid_pgid mcp_tool_usage.server_label
        mcp_tool_usage.status_label mcp_tool_usage.error_label mcp_tool_usage.server_breakdown_heading
        mcp_tool_usage.startup_timing_col_p50 mcp_tool_usage.startup_timing_col_p95
        mcp_tool_usage.col_status mcp_tool_usage.owner_core
      ]
    }
  }.freeze
  ADMIN_ENGLISH_MATCH_BASELINE = { "de" => 127, "la" => 75 }.freeze

  INTENTIONAL_JOB_EPIC_ENGLISH_MATCHES = {
    "de" => {
      "approved German domain term" => %w[
        jobs.title jobs.chat jobs.tab_workflows jobs.conversation_select_workflow jobs.timeline_select_workflow
        jobs.timeline_workflow_summary jobs.detail_epic jobs.review_version_workflow jobs.subject_epics
        jobs.subject_jobs jobs.subject_workflows jobs.column_epic jobs.column_repository jobs.column_agent
        jobs.column_job jobs.column_workflow
        jobs.form_repository_label jobs.form_agent_label jobs.transcript_kind_agent jobs.aria_job
        jobs.skill_job_agent_label epics.title epics.detail_label epics.tab_jobs_one epics.tab_jobs_other
        epics.jobs_section epics.deployment_stage_partial epics.repository epics.jobs_count_one
        epics.jobs_count_other epics.form_repository
      ],
      "product or established UI term" => %w[
        jobs.start_discussion_chat_prompt_label jobs.retry_provider_label jobs.tab_review
        jobs.artifact_image_alt jobs.artifact_provenance_viewport jobs.detail_provider jobs.detail_branch
        jobs.approval_status jobs.workflow_divergence_branch jobs.grader_status_label jobs.run_diff
        jobs.prepare_failure_status_label jobs.source_diff jobs.review_version_label jobs.attachment_google_doc
        jobs.coverage_project_col_status jobs.transcript_kind_system jobs.skill_job_section_pick
        jobs.delivery.status_label
      ],
      "token, abbreviation, placeholder, or interpolated identifier" => %w[
        jobs.navigation_jump_option jobs.conversation_iteration jobs.classification_duration
        jobs.artifact_erd_primary_key jobs.pr_checks_head_sha jobs.prepare_failure_soft_syrus_yml
        jobs.prepare_failure_soft_prepare jobs.review_version_prefix jobs.review_version_separator
        jobs.attachment_google_doc_placeholder jobs.pr_syrus
      ],
      "shared German word" => %w[jobs.readiness_optional]
    },
    "la" => {
      "Latin domain term pending competent review" => %w[
        jobs.review_version_workflow jobs.review_version_run
      ],
      "valid Latin or established UI term" => %w[
        jobs.detail_provider jobs.provider_setting_default jobs.approval_status jobs.grader_status_label
        jobs.prepare_failure_status_label jobs.review_settings_off jobs.review_metric_gutter_off
        jobs.review_resolve_comment jobs.coverage_project_col_status jobs.delivery.status_label
      ],
      "token, abbreviation, placeholder, or interpolated identifier" => %w[
        jobs.navigation_jump_option jobs.classification_duration jobs.artifact_erd_primary_key
        jobs.artifact_provenance_viewport jobs.prepare_failure_soft_syrus_yml
        jobs.prepare_failure_soft_prepare jobs.review_version_prefix jobs.review_version_separator
        jobs.attachment_google_doc_placeholder jobs.pr_syrus
      ]
    }
  }.freeze
  JOB_EPIC_ENGLISH_MATCH_BASELINE = {
    "de" => { "jobs" => 63, "epics" => 19 },
    "la" => { "jobs" => 35, "epics" => 15 }
  }.freeze
  REVIEWED_JOB_EPIC_PREFIXES = %w[
    merge_train approval grader prepare_failure review_version delivery
  ].freeze

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

  it "translates the admin catalog except for documented intentional matches" do
    locales = locale_namespaces(Rails.root.join("app/frontend/i18n/locales"))
    english = flatten_json(locales.fetch("en").fetch("admin"))

    INTENTIONAL_ADMIN_ENGLISH_MATCHES.each do |locale, matches_by_reason|
      documented_matches = matches_by_reason.values.flatten
      actual_matches = english.filter_map do |key, value|
        key if dig_key(locales.fetch(locale).fetch("admin"), key) == value
      end

      expect(actual_matches.sort).to eq(documented_matches.sort)
      expect(actual_matches.size).to be < ADMIN_ENGLISH_MATCH_BASELINE.fetch(locale)
      expect(documented_matches).not_to include(nil)
      expect(matches_by_reason.keys).to all(be_present)
    end
  end

  it "preserves admin placeholders and the approved German register and terminology" do
    locales = locale_namespaces(Rails.root.join("app/frontend/i18n/locales"))
    english = flatten_json(locales.fetch("en").fetch("admin"))

    %w[de la].each do |locale|
      localized = flatten_json(locales.fetch(locale).fetch("admin"))
      english.each do |key, value|
        expect(interpolation_names(localized.fetch(key))).to eq(interpolation_names(value)), "#{locale}.admin.#{key} changed placeholders"
      end
    end

    german_copy = flatten_json(locales.fetch("de").fetch("admin")).values.join("\n")
    expect(german_copy).not_to match(/\b(?:Sie|Ihnen|Ihr\p{L}*)\b/)
    expect(german_copy).not_to match(/\b(?:Runs?|Repositories|Ausführung(?:en)?|Arbeitsabl(?:auf|äufe))\b/)
    expect(dig_key(locales.dig("de", "admin"), "overview.active_runs")).to eq("Aktive Läufe")
    expect(dig_key(locales.dig("de", "admin"), "overview.resource_samples")).to eq("{{count}} Stichproben")
    expect(dig_key(locales.dig("de", "admin"), "users.smart_folders")).to eq("Intelligente Ordner")
    expect(dig_key(locales.dig("de", "admin"), "users.matching")).to eq("{{count}} Treffer")
    expect(dig_key(locales.dig("de", "admin"), "github_app.step_1")).to start_with("Installiere")

    expected_repository_counts = {
      "en" => [ "{{count}} PAT-only repository", "{{count}} PAT-only repositories" ],
      "de" => [ "{{count}} reines PAT-Repository", "{{count}} reine PAT-Repositorys" ],
      "la" => [ "{{count}} receptaculum PAT-tantum", "{{count}} receptacula PAT-tantum" ]
    }
    expected_repository_counts.each do |locale, (one, other)|
      installations = locales.dig(locale, "admin", "installations")
      expect(installations).not_to have_key("pat_repos_count")
      expect(installations.fetch("pat_repos_count_one")).to eq(one)
      expect(installations.fetch("pat_repos_count_other")).to eq(other)
    end
  end

  it "translates the Job and Epic catalogs except for documented intentional matches" do
    locales = locale_namespaces(Rails.root.join("app/frontend/i18n/locales"))

    INTENTIONAL_JOB_EPIC_ENGLISH_MATCHES.each do |locale, matches_by_reason|
      documented_matches = matches_by_reason.values.flatten
      actual_matches = %w[jobs epics].flat_map do |namespace|
        english = flatten_json(locales.dig("en", namespace))
        localized = flatten_json(locales.dig(locale, namespace))
        english.filter_map { |key, value| "#{namespace}.#{key}" if localized.fetch(key) == value }
      end

      expect(actual_matches.sort).to eq(documented_matches.sort)
      expect(matches_by_reason.keys).to all(be_present)

      %w[jobs epics].each do |namespace|
        remaining = actual_matches.count { |key| key.start_with?("#{namespace}.") }
        expect(remaining).to be < JOB_EPIC_ENGLISH_MATCH_BASELINE.dig(locale, namespace)
      end
    end
  end

  it "preserves Job and Epic placeholders, plurals, and approved German copy" do
    locales = locale_namespaces(Rails.root.join("app/frontend/i18n/locales"))

    %w[de la].each do |locale|
      %w[jobs epics].each do |namespace|
        english = flatten_json(locales.dig("en", namespace))
        localized = flatten_json(locales.dig(locale, namespace))
        english.each do |key, value|
          next unless REVIEWED_JOB_EPIC_PREFIXES.any? { |prefix| key == prefix || key.start_with?("#{prefix}.", "#{prefix}_") }

          expect(interpolation_names(localized.fetch(key))).to eq(interpolation_names(value)),
            "#{locale}.#{namespace}.#{key} changed placeholders"
        end
      end
    end

    german_copy = %w[jobs epics].flat_map { |namespace| flatten_json(locales.dig("de", namespace)).values }.join("\n")
    expect(german_copy).not_to match(/\b(?:Ihnen|Ihr\p{L}*)\b/)
    expect(german_copy).not_to match(/\b(?:Aufgab\p{L}*|Runs?|Arbeitsabl\p{L}*)\b/)
    expect(locales.dig("de", "jobs", "run_count_one")).to eq("{{count}} Lauf")
    expect(locales.dig("de", "jobs", "run_count_other")).to eq("{{count}} Läufe")
    expect(locales.dig("de", "jobs")).not_to have_key("bulk_close_confirm")
    expect(locales.dig("de", "jobs", "bulk_close_confirm_one")).to eq("{{count}} ausgewählten Job schließen?")
    expect(locales.dig("de", "jobs", "bulk_close_confirm_other")).to eq("{{count}} ausgewählte Jobs schließen?")
    expect(locales.dig("de", "epics", "merge_train_members_one")).to eq("{{count}} Mitglied")
    expect(locales.dig("de", "epics", "merge_train_members_other")).to eq("{{count}} Mitglieder")
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
    expect(dig_key(german, "themes.description")).to eq("Verwalte deine eigenen Farbthemen.")
    expect(dig_key(german, "profile.repositories")).to eq("Repositorys")
    expect(dig_key(german, "profile.jobs")).to eq("Jobs")
    expect(dig_key(german, "repository.health_repair_start")).to eq("Reparatur-Job starten")
    expect(dig_key(german, "delivery.heading")).to eq("Auslieferung")
    expect(dig_key(german, "provider_routing.trigger")).to eq("Auslöser")
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
    expect(dig_key(latin, "account_settings.provider_availability_desc")).to include("Jobs huius praebitoris")
    expect(dig_key(latin, "scheduled_tasks.schedule_placeholder")).to eq("Omni die Lunae hora 09:00")
    expect(dig_key(latin, "credential_cards.muse_description")).to include("cursibus operum")
    expect(dig_key(latin, "repository.syrus_yml_coverage")).to eq("Cobertura")
    expect(dig_key(latin, "provider_routing.remove")).to eq("Removere")
  end

  it "detects either missing half of a plural pair" do
    expect(plural_pair_failures("chat" => { "items_one" => "one" })).to eq([ "chat.items missing other" ])
    expect(plural_pair_failures("chat" => { "items_other" => "many" })).to eq([ "chat.items missing one" ])
  end

  it "keeps the failed repair cap count-driven in every locale" do
    settings = locale_namespaces(Rails.root.join("app/frontend/i18n/locales")).transform_values { |locales| locales.fetch("settings") }

    supported_locales.each do |locale|
      repository = settings.fetch(locale).fetch("repository")
      expect(repository).not_to have_key("health_repair_failed_cap")
      expect(interpolation_names(repository.fetch("health_repair_failed_cap_one"))).to eq(%w[count max])
      expect(interpolation_names(repository.fetch("health_repair_failed_cap_other"))).to eq(%w[count max])
    end

    expect(settings.dig("de", "repository", "health_repair_failed_cap_one")).to include("fehlgeschlagener Reparatur-Job")
    expect(settings.dig("la", "repository", "health_repair_failed_cap_one")).to include("officium reparationis deficiens")
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
