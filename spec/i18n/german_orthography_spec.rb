require "rails_helper"
require "json"
require "set"
require "strscan"
require "tempfile"
require "yaml"

RSpec.describe "German localization orthography", type: :unit do
  Entry = Data.define(:file, :key, :value)
  Finding = Data.define(:file, :key, :token) do
    def coordinate = "#{file}:#{key}"
    def to_s = "#{coordinate}: #{token}"
  end

  # These native spellings contain letter pairs that a deliberately broad
  # transliteration search would otherwise flag. Keep this list linguistic,
  # never use it to excuse an ASCII spelling that ought to contain ä/ö/ü/ß.
  LEGITIMATE_WORDS = %w[
    Steuer Neuer Quelle Dauer zuerst manuell visuell Vertrauen muss dass lassen
  ].freeze

  UMLAUT_TRANSLITERATION_STEMS = %w[
    aeltest aender angehaeng aufzaehl ausfuehr ausgewaehl auswaehl bestaet
    einfueg einrueck enthaelt faelle fehlschlaeg fremdschluessel frueh fuehr
    geoeffnet gepruef gewaehl groess hinzugefueg hoehe kapazitaet kuerz laedt
    laeuf loesch lueck menue moeglich noetig oeffentlich oeffn praezision
    prioritaet pruef rueck schluessel schriftgroess staerk statusuebergang ueberschrift
    uebersprungen ungefaehr ursprueng verfueg veroeffentlich verschluessel
    vollstaendig waeh woerter zeichenflaech zeichenlaeng zugaenglich
  ].freeze
  UMLAUT_TRANSLITERATION = /(?:#{UMLAUT_TRANSLITERATION_STEMS.join('|')}|fuer|ueber)/
  ESZETT_TRANSLITERATION = /(?:schliess|gross|heiss|weiss|strasse)/
  TOKEN = /[[:alpha:]]+/i

  # Temporary debt is recorded by exact catalog coordinate. Deleting or
  # correcting an entry must delete its coordinate here in the same change.
  DEBT_BASELINE = %w[
    app/frontend/i18n/locales/de/admin.json:mcp_tool_usage.card_gap_ranking_empty
    app/frontend/i18n/locales/de/admin.json:mcp_tool_usage.card_gap_ranking_heading
    app/frontend/i18n/locales/de/nav.json:smart_folder.names.admin_queue_low_priority_maintenance
    app/frontend/i18n/locales/de/nav.json:smart_folder_names.admin_queue_runs
    app/frontend/i18n/locales/de/nav.json:smart_folder_names.admin_queue_low_priority_maintenance
    app/frontend/i18n/locales/de/nav.json:smart_folder_names.repositories_recent
    desktop/electron/i18nCatalog.ts:adopt_existing.body
    desktop/electron/i18nCatalog.ts:adopt_existing.confirm_label
    desktop/electron/i18nCatalog.ts:adopt_existing.delete_all
    desktop/electron/i18nCatalog.ts:adopt_existing.fresh_hint
    desktop/electron/i18nCatalog.ts:adopt_existing.keep_hint
    desktop/electron/i18nCatalog.ts:backend.checking
    desktop/electron/i18nCatalog.ts:backend.containers_down.body
    desktop/electron/i18nCatalog.ts:backend.daemon_down.body
    desktop/electron/i18nCatalog.ts:backend.daemon_down.title
    desktop/electron/i18nCatalog.ts:backend.data_gone.body
    desktop/electron/i18nCatalog.ts:backend.default.body
    desktop/electron/i18nCatalog.ts:backend.reset_hint
    desktop/electron/i18nCatalog.ts:backend.stopped.body
    desktop/electron/i18nCatalog.ts:common.back
    desktop/electron/i18nCatalog.ts:install_failed.code_12
    desktop/electron/i18nCatalog.ts:install_failed.code_30
    desktop/electron/i18nCatalog.ts:install_failed.code_31
    desktop/electron/i18nCatalog.ts:install_failed.code_32
    desktop/electron/i18nCatalog.ts:install_failed.code_41
    desktop/electron/i18nCatalog.ts:install_progress.env_check
    desktop/electron/i18nCatalog.ts:install_progress.runtime_check
    desktop/electron/i18nCatalog.ts:onboarding.adopt_running.title
    desktop/electron/i18nCatalog.ts:onboarding.connect.check_failed
    desktop/electron/i18nCatalog.ts:onboarding.connect.checking
    desktop/electron/i18nCatalog.ts:onboarding.done_local
    desktop/electron/i18nCatalog.ts:onboarding.precheck_mac
    desktop/electron/i18nCatalog.ts:onboarding.precheck_pc
    desktop/electron/i18nCatalog.ts:onboarding.welcome.local_mac
    desktop/electron/i18nCatalog.ts:onboarding.welcome.local_windows
    desktop/electron/i18nCatalog.ts:onboarding.welcome.subtitle
    desktop/electron/i18nCatalog.ts:port_conflict.invalid
    desktop/electron/i18nCatalog.ts:port_conflict.subtitle
    desktop/electron/i18nCatalog.ts:repo_picker.select
    desktop/electron/i18nCatalog.ts:repo_picker.selected
    desktop/electron/i18nCatalog.ts:runtime.auto_install_body
    desktop/electron/i18nCatalog.ts:runtime.check_now
    desktop/electron/i18nCatalog.ts:runtime.install_wsl_first
    desktop/electron/i18nCatalog.ts:runtime.installing_subtitle
    desktop/electron/i18nCatalog.ts:runtime.missing_subtitle
    desktop/electron/i18nCatalog.ts:runtime.missing_title
    desktop/electron/i18nCatalog.ts:runtime.needs_other
    desktop/electron/i18nCatalog.ts:runtime.needs_setup_title
    desktop/electron/i18nCatalog.ts:runtime.needs_windows
    desktop/electron/i18nCatalog.ts:runtime.open
    desktop/electron/i18nCatalog.ts:runtime.open_step
    desktop/electron/i18nCatalog.ts:runtime.recommend_mac
    desktop/electron/i18nCatalog.ts:runtime.recommend_windows
    desktop/electron/i18nCatalog.ts:runtime.return_step
    desktop/electron/i18nCatalog.ts:runtime.running_installer
    desktop/electron/i18nCatalog.ts:runtime.wait_available
    desktop/electron/i18nCatalog.ts:runtime.wsl_body
    desktop/electron/i18nCatalog.ts:dialog.action_failed
    desktop/electron/i18nCatalog.ts:dialog.action_failed_detail
    desktop/electron/i18nCatalog.ts:dialog.data_gone_detail
    desktop/electron/i18nCatalog.ts:dialog.pause_runs_detail
    desktop/electron/i18nCatalog.ts:dialog.reset
    desktop/electron/i18nCatalog.ts:dialog.reset_button
    desktop/electron/i18nCatalog.ts:dialog.reset_title
    desktop/electron/i18nCatalog.ts:dialog.resume_runs_detail
    desktop/electron/i18nCatalog.ts:dialog.setup_detail
    desktop/electron/i18nCatalog.ts:dialog.stop_detail
    desktop/electron/i18nCatalog.ts:dialog.uninstall_data
    desktop/electron/i18nCatalog.ts:dialog.update_backend_detail
    desktop/electron/i18nCatalog.ts:dialog.update_busy_test
    desktop/electron/i18nCatalog.ts:notification.pr_merged
    desktop/electron/i18nCatalog.ts:notification.pr_ready
    desktop/electron/i18nCatalog.ts:renderer.already_signed_in
    desktop/electron/i18nCatalog.ts:renderer.behind
    desktop/electron/i18nCatalog.ts:renderer.checking
    desktop/electron/i18nCatalog.ts:renderer.choose
    desktop/electron/i18nCatalog.ts:renderer.choose_repository
    desktop/electron/i18nCatalog.ts:renderer.clear
    desktop/electron/i18nCatalog.ts:renderer.cli_add_path
    desktop/electron/i18nCatalog.ts:renderer.cli_install_required
    desktop/electron/i18nCatalog.ts:renderer.cli_new_terminal
    desktop/electron/i18nCatalog.ts:renderer.close_compose
    desktop/electron/i18nCatalog.ts:renderer.dismiss
    desktop/electron/i18nCatalog.ts:renderer.feedback_placeholder
    desktop/electron/i18nCatalog.ts:renderer.job_unavailable
    desktop/electron/i18nCatalog.ts:renderer.menu_bar
    desktop/electron/i18nCatalog.ts:renderer.no_test_plan
    desktop/electron/i18nCatalog.ts:renderer.open_actions
    desktop/electron/i18nCatalog.ts:renderer.open_in_syrus
    desktop/electron/i18nCatalog.ts:renderer.open_new_terminal
    desktop/electron/i18nCatalog.ts:renderer.open_pr
    desktop/electron/i18nCatalog.ts:renderer.open_pull_request
    desktop/electron/i18nCatalog.ts:renderer.open_syrus
    desktop/electron/i18nCatalog.ts:renderer.open_url
    desktop/electron/i18nCatalog.ts:renderer.press_shortcut
    desktop/electron/i18nCatalog.ts:renderer.running
    desktop/electron/i18nCatalog.ts:renderer.runs
    desktop/electron/i18nCatalog.ts:renderer.shortcut_cleared
    desktop/electron/i18nCatalog.ts:renderer.signin_refresh_detail
    desktop/electron/i18nCatalog.ts:renderer.skill_added
    desktop/electron/i18nCatalog.ts:renderer.skill_install_title
    desktop/electron/i18nCatalog.ts:renderer.status_loading
    desktop/electron/i18nCatalog.ts:screen.detail
    desktop/electron/i18nCatalog.ts:self_install.open_new_detail
    desktop/electron/i18nCatalog.ts:self_install.open_new_failed
    desktop/electron/i18nCatalog.ts:self_install.open_old_detail
    desktop/electron/i18nCatalog.ts:self_install.open_old_failed
    desktop/electron/i18nCatalog.ts:self_install.replace_detail
    desktop/electron/i18nCatalog.ts:shell.data_folder
    desktop/electron/i18nCatalog.ts:shell.install_log
    desktop/electron/i18nCatalog.ts:shell.open
    desktop/electron/i18nCatalog.ts:shell.projects_root
    desktop/electron/i18nCatalog.ts:shell.reset_test
    desktop/electron/i18nCatalog.ts:shell.window_only
    desktop/electron/i18nCatalog.ts:updates.failed
    desktop/electron/i18nCatalog.ts:updates.failed_detail
    desktop/electron/i18nCatalog.ts:updates.ready_detail
    desktop/electron/i18nCatalog.ts:updates.unavailable
    desktop/electron/i18nCatalog.ts:updates.unavailable_mac_detail
    desktop/electron/i18nCatalog.ts:updates.unavailable_windows_detail
    plugins/admin_mysql/app/frontend/i18n/locales/de/admin_mysql.json:col_rows_examined
    plugins/admin_mysql/app/frontend/i18n/locales/de/admin_mysql.json:confirm_kill_query
    plugins/admin_mysql/app/frontend/i18n/locales/de/admin_mysql.json:killed_query
    plugins/admin_mysql/app/frontend/i18n/locales/de/admin_mysql.json:slow_log_unavailable
    plugins/admin_mysql/app/frontend/i18n/locales/de/admin_mysql.json:statement_digests_unavailable
    plugins/admin_mysql/app/frontend/i18n/locales/de/admin_mysql.json:tool_full_error
    plugins/admin_mysql/app/frontend/i18n/locales/de/admin_mysql.json:tool_full_redacted_statement
    plugins/agent_memory/app/frontend/i18n/locales/de/agent_memory.json:tool_audit_event_count_one
    plugins/agent_memory/app/frontend/i18n/locales/de/agent_memory.json:tool_audit_event_count_other
    plugins/agent_memory/app/frontend/i18n/locales/de/agent_memory.json:tool_audit_trail
    plugins/agent_memory/app/frontend/i18n/locales/de/agent_memory.json:tool_close
    plugins/agent_memory/app/frontend/i18n/locales/de/agent_memory.json:tool_content_change
    plugins/cognitive_review/app/frontend/i18n/locales/de/cognitive_review.json:actions.close_discussion
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:aria_change_mode
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:aria_change_summary
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:close_comment_drawer
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:empty_chat
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:error_write
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:notice_comment_added
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:notice_reply_added
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:notice_saved_suggestion
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:notice_suggestion_reviewed
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:open
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:optional_change_summary
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:pending_owner_review
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:preview_not_accessible
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:select_doc
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:smart_folders_aria
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:status.public
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:suggest_changes
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:tool_confirmation_reason
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:tool_confirmation_required
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:tool_empty_original
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:tool_empty_proposed
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:tool_no_confirmation_reason
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:tool_no_sections
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:tool_skipped_sections_one
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:tool_skipped_sections_other
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:tool_state_transition
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:tool_suggested_change_summary
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:tool_suggestion_pending_summary
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:tool_word_count_other
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:toolbar.bulleted_list
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:toolbar.indent_list_item
    plugins/design_docs/app/frontend/i18n/locales/de/design_docs.json:visibility_public
    plugins/mysql_db_browser/app/frontend/i18n/locales/de/mysql_db_browser.json:tool_character_max_length
    plugins/mysql_db_browser/app/frontend/i18n/locales/de/mysql_db_browser.json:tool_columns_unavailable
    plugins/mysql_db_browser/app/frontend/i18n/locales/de/mysql_db_browser.json:tool_data_size
    plugins/mysql_db_browser/app/frontend/i18n/locales/de/mysql_db_browser.json:tool_foreign_key_list
    plugins/mysql_db_browser/app/frontend/i18n/locales/de/mysql_db_browser.json:tool_foreign_keys
    plugins/mysql_db_browser/app/frontend/i18n/locales/de/mysql_db_browser.json:tool_index_size
    plugins/mysql_db_browser/app/frontend/i18n/locales/de/mysql_db_browser.json:tool_key
    plugins/mysql_db_browser/app/frontend/i18n/locales/de/mysql_db_browser.json:tool_no_foreign_keys
    plugins/mysql_db_browser/app/frontend/i18n/locales/de/mysql_db_browser.json:tool_numeric_precision
    plugins/mysql_db_browser/app/frontend/i18n/locales/de/mysql_db_browser.json:tool_query_no_rows
    plugins/mysql_db_browser/app/frontend/i18n/locales/de/mysql_db_browser.json:tool_rows_returned_truncated_one
    plugins/mysql_db_browser/app/frontend/i18n/locales/de/mysql_db_browser.json:tool_rows_returned_truncated_other
    plugins/mysql_db_browser/app/frontend/i18n/locales/de/mysql_db_browser.json:tool_truncated_notice
    plugins/test_insights/app/frontend/i18n/locales/de/test_insights.json:repo_back_to_tests
    plugins/test_insights/app/frontend/i18n/locales/de/test_insights.json:repo_click_to_open
    plugins/test_insights/app/frontend/i18n/locales/de/test_insights.json:repo_col_recent_failures
    plugins/test_insights/app/frontend/i18n/locales/de/test_insights.json:repo_columns_reset
    plugins/test_insights/app/frontend/i18n/locales/de/test_insights.json:repo_no_search_results
    plugins/test_insights/app/frontend/i18n/locales/de/test_insights.json:repo_previous
    plugins/test_insights/app/frontend/i18n/locales/de/test_insights.json:status_skipped
    plugins/test_insights/app/frontend/i18n/locales/de/test_insights.json:tool_backtrace_output
    plugins/test_insights/app/frontend/i18n/locales/de/test_insights.json:tool_failed_error_cases
    plugins/test_insights/app/frontend/i18n/locales/de/test_insights.json:tool_recent_executions
    plugins/test_insights/app/frontend/i18n/locales/de/test_insights.json:tool_run_results_summary_one
    plugins/test_insights/app/frontend/i18n/locales/de/test_insights.json:tool_run_results_summary_other
    plugins/test_insights/app/frontend/i18n/locales/de/test_insights.json:tool_slow_cases
    plugins/test_insights/app/frontend/i18n/locales/de/test_insights.json:tool_test_counts
    plugins/throughput/app/frontend/i18n/locales/de/throughput.json:row_optimistic_capacity
    plugins/throughput/app/frontend/i18n/locales/de/throughput.json:row_prs_opened
    plugins/throughput/app/frontend/i18n/locales/de/throughput.json:section_latency_capacity
    plugins/whiteboard/app/frontend/i18n/locales/de/whiteboard.json:tool_action_deleted_element
    plugins/whiteboard/app/frontend/i18n/locales/de/whiteboard.json:tool_elements_added
    plugins/whiteboard/app/frontend/i18n/locales/de/whiteboard.json:tool_field_approx_size
    plugins/whiteboard/app/frontend/i18n/locales/de/whiteboard.json:tool_field_font_size
    plugins/whiteboard/app/frontend/i18n/locales/de/whiteboard.json:tool_field_height
    plugins/whiteboard/app/frontend/i18n/locales/de/whiteboard.json:tool_field_stroke_width
    plugins/whiteboard/app/frontend/i18n/locales/de/whiteboard.json:tool_missing_result
    plugins/whiteboard/app/frontend/i18n/locales/de/whiteboard.json:tool_missing_result_summary
    plugins/whiteboard/app/frontend/i18n/locales/de/whiteboard.json:tool_recovery_check_canvas
  ].to_set.freeze

  def flatten_values(value, prefix = [], &block)
    case value
    when Hash
      value.each { |key, child| flatten_values(child, prefix + [ key.to_s ], &block) }
    when Array
      value.each_with_index { |child, index| flatten_values(child, prefix + [ index.to_s ], &block) }
    when String
      yield(prefix.join("."), value)
    end
  end

  def structured_entries(path, contents: File.read(path))
    relative = Pathname(path).relative_path_from(Rails.root).to_s
    parsed = path.to_s.end_with?(".json") ? JSON.parse(contents) : YAML.safe_load(contents, aliases: true)
    parsed = parsed.fetch("de") if relative == "config/locales/de.yml"

    entries = []
    flatten_values(parsed) { |key, value| entries << Entry.new(relative, key, value) }
    entries
  end

  def desktop_entries(path = Rails.root.join("desktop/electron/i18nCatalog.ts"), contents: File.read(path))
    body = contents[/\bconst deMessages\s*=\s*\{(?<body>.*?)\n\}\s+satisfies\s+Record<DesktopMessageKey, string>/m, :body]
    raise "Could not find the bounded deMessages object in #{path}" unless body

    scanner = StringScanner.new(body)
    source = Pathname(path)
    relative = source.absolute? ? source.relative_path_from(Rails.root).to_s : source.to_s
    entries = []
    until scanner.eos?
      scanner.skip(/\s*/)
      break if scanner.eos?

      match = scanner.scan(/"(?<key>(?:[^"\\]|\\.)+)"\s*:\s*(?:"(?<double_value>(?:[^"\\]|\\.)*)"|'(?<single_value>(?:[^'\\]|\\.)*)')\s*,?/)
      raise "Unsupported deMessages entry near: #{scanner.peek(80).lines.first.to_s.strip}" unless match

      encoded_value = scanner[:double_value] || scanner[:single_value].gsub(/(?<!\\)"/, '\\"').gsub("\\'", "'")
      entries << Entry.new(
        relative,
        JSON.parse(%("#{scanner[:key]}")),
        JSON.parse(%("#{encoded_value}"))
      )
    end
    entries
  end

  def catalog_entries
    paths = [ Rails.root.join("config/locales/de.yml") ]
    paths.concat(Dir.glob(Rails.root.join("app/frontend/i18n/locales/de/*.json")).sort)
    paths.concat(Dir.glob(Rails.root.join("plugins/*/app/frontend/i18n/locales/de/*.json")).sort)
    paths.flat_map { |path| structured_entries(Pathname(path)) } + desktop_entries
  end

  def code_stripped(value)
    value
      .gsub(/\{\{.*?\}\}/, " ")
      .gsub(/`.*?`/, " ")
      .gsub(%r{\b(?:https?://|[\w.-]+/)[^\s]+}, " ")
  end

  def legitimate_word?(token)
    LEGITIMATE_WORDS.any? { |word| token.match?(/\A#{Regexp.escape(word)}/i) }
  end

  def findings_for(entries)
    entries.flat_map do |entry|
      code_stripped(entry.value).scan(TOKEN).filter_map do |token|
        next if legitimate_word?(token)
        normalized = token.downcase
        next unless normalized.match?(UMLAUT_TRANSLITERATION) || normalized.match?(ESZETT_TRANSLITERATION)

        Finding.new(entry.file, entry.key, token)
      end
    end
  end

  def unexpected_findings(entries, baseline: DEBT_BASELINE)
    findings_for(entries).reject { |finding| baseline.include?(finding.coordinate) }
  end

  def stale_debt_for(entries, baseline: DEBT_BASELINE)
    baseline - findings_for(entries).map(&:coordinate).to_set
  end

  def unexpected_message(findings)
    <<~MESSAGE
      German localization values require native German spelling with umlauts and ß. Fix each value (keys and code tokens are ignored):
      #{findings.map(&:to_s).sort.join("\n")}
    MESSAGE
  end

  it "requires native German spelling in every maintained catalog" do
    entries = catalog_entries
    findings = findings_for(entries)
    stale_debt = stale_debt_for(entries)
    unexpected = findings.reject { |finding| DEBT_BASELINE.include?(finding.coordinate) }

    expect(stale_debt).to be_empty, <<~MESSAGE
      German orthography debt entries no longer violate the rule; remove these stale baseline coordinates:
      #{stale_debt.to_a.sort.join("\n")}
    MESSAGE
    expect(unexpected).to be_empty, unexpected_message(unexpected)
  end

  it "keeps every documented legitimate spelling exercised by production catalogs" do
    tokens = catalog_entries.flat_map { |entry| code_stripped(entry.value).scan(TOKEN) }
    missing = LEGITIMATE_WORDS.reject { |word| tokens.any? { |token| token.match?(/\A#{Regexp.escape(word)}/i) } }

    expect(missing).to be_empty, "Remove stale legitimate-word exceptions: #{missing.join(', ')}"
  end

  it "accepts native umlauts and ß and rejects representative transliterations" do
    good = [ Entry.new("fixture.json", "native", "Kürzen, ändern, löschen, für, über, Straße, groß") ]
    bad = [ Entry.new("fixture.json", "ascii", "Kuerzen Aendern Loeschen fuer ueber Strasse gross") ]

    expect(findings_for(good)).to be_empty
    expect(findings_for(bad).map(&:token)).to eq(%w[Kuerzen Aendern Loeschen fuer ueber Strasse gross])
  end

  it "accepts legitimate ae, oe, ue, and ss words" do
    value = "Steuer Neuer Quelle Dauer zuerst manuell visuell Vertrauen muss dass lassen"

    expect(findings_for([ Entry.new("fixture.json", "legitimate", value) ])).to be_empty
  end

  it "checks values while ignoring translation keys and code tokens" do
    entries = [ Entry.new("fixture.json", "Zurueck.schliessen", "`Zurueck` {{ueber_value}} https://example.test/Strasse") ]

    expect(findings_for(entries)).to be_empty
  end

  it "parses YAML, nested JSON, plugin JSON, and only the bounded desktop German object" do
    yaml = Tempfile.new([ "de", ".yml" ], Rails.root.join("tmp"))
    json = Tempfile.new([ "de", ".json" ], Rails.root.join("tmp"))
    begin
      yaml.write("de:\n  nested:\n    label: Zurueck\n")
      json.write('{"nested":{"label":"Oeffnen"}}')
      yaml.flush
      json.flush
      desktop = <<~TS
        const enMessages = { "ignored": "Zurueck" }
        const deMessages = {
          "desktop.label": "Schliessen",
        } satisfies Record<DesktopMessageKey, string>
        const laMessages = { "ignored": "Zurueck" }
      TS

      expect(structured_entries(Pathname(yaml.path)).map(&:key)).to eq([ "de.nested.label" ])
      expect(structured_entries(Pathname(json.path)).map(&:key)).to eq([ "nested.label" ])
      expect(desktop_entries(Pathname("desktop/src/i18n.ts"), contents: desktop)).to eq([
        Entry.new("desktop/src/i18n.ts", "desktop.label", "Schliessen")
      ])
    ensure
      yaml.close!
      json.close!
    end
  end

  it "reports actionable stable coordinates and ratchets corrected debt away" do
    entry = Entry.new("plugins/example/app/frontend/i18n/locales/de/example.json", "dialog.close", "Schliessen")
    finding = findings_for([ entry ]).fetch(0)

    expect(finding.to_s).to eq("plugins/example/app/frontend/i18n/locales/de/example.json:dialog.close: Schliessen")
    expect(unexpected_message([ finding ])).to include("native German spelling with umlauts and ß", finding.to_s)
    expect(unexpected_findings([ entry ], baseline: Set[finding.coordinate])).to be_empty
    corrected = entry.with(value: "Schließen")
    expect(findings_for([ corrected ])).to be_empty
    expect(stale_debt_for([ corrected ], baseline: Set[finding.coordinate])).to eq(Set[finding.coordinate])
  end
end
