require "rails_helper"
require "json"
require "set"
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
    desktop/src/i18n.ts:adopt_existing.body
    desktop/src/i18n.ts:adopt_existing.confirm_label
    desktop/src/i18n.ts:adopt_existing.delete_all
    desktop/src/i18n.ts:adopt_existing.fresh_hint
    desktop/src/i18n.ts:adopt_existing.keep_hint
    desktop/src/i18n.ts:backend.checking
    desktop/src/i18n.ts:backend.containers_down.body
    desktop/src/i18n.ts:backend.daemon_down.body
    desktop/src/i18n.ts:backend.daemon_down.title
    desktop/src/i18n.ts:backend.data_gone.body
    desktop/src/i18n.ts:backend.default.body
    desktop/src/i18n.ts:backend.reset_hint
    desktop/src/i18n.ts:backend.stopped.body
    desktop/src/i18n.ts:common.back
    desktop/src/i18n.ts:install_failed.code_12
    desktop/src/i18n.ts:install_failed.code_30
    desktop/src/i18n.ts:install_failed.code_31
    desktop/src/i18n.ts:install_failed.code_32
    desktop/src/i18n.ts:install_failed.code_41
    desktop/src/i18n.ts:install_progress.env_check
    desktop/src/i18n.ts:install_progress.runtime_check
    desktop/src/i18n.ts:onboarding.adopt_running.title
    desktop/src/i18n.ts:onboarding.connect.check_failed
    desktop/src/i18n.ts:onboarding.connect.checking
    desktop/src/i18n.ts:onboarding.done_local
    desktop/src/i18n.ts:onboarding.precheck_mac
    desktop/src/i18n.ts:onboarding.precheck_pc
    desktop/src/i18n.ts:onboarding.welcome.local_mac
    desktop/src/i18n.ts:onboarding.welcome.local_windows
    desktop/src/i18n.ts:onboarding.welcome.subtitle
    desktop/src/i18n.ts:port_conflict.invalid
    desktop/src/i18n.ts:port_conflict.subtitle
    desktop/src/i18n.ts:repo_picker.select
    desktop/src/i18n.ts:repo_picker.selected
    desktop/src/i18n.ts:runtime.auto_install_body
    desktop/src/i18n.ts:runtime.check_now
    desktop/src/i18n.ts:runtime.install_wsl_first
    desktop/src/i18n.ts:runtime.installing_subtitle
    desktop/src/i18n.ts:runtime.missing_subtitle
    desktop/src/i18n.ts:runtime.missing_title
    desktop/src/i18n.ts:runtime.needs_other
    desktop/src/i18n.ts:runtime.needs_setup_title
    desktop/src/i18n.ts:runtime.needs_windows
    desktop/src/i18n.ts:runtime.open
    desktop/src/i18n.ts:runtime.open_step
    desktop/src/i18n.ts:runtime.recommend_mac
    desktop/src/i18n.ts:runtime.recommend_windows
    desktop/src/i18n.ts:runtime.return_step
    desktop/src/i18n.ts:runtime.running_installer
    desktop/src/i18n.ts:runtime.wait_available
    desktop/src/i18n.ts:runtime.wsl_body
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

  def desktop_entries(path = Rails.root.join("desktop/src/i18n.ts"), contents: File.read(path))
    body = contents[/\bconst deMessages\s*=\s*\{(?<body>.*?)\n\}\s+satisfies\s+Record<DesktopMessageKey, string>/m, :body]
    raise "Could not find the bounded deMessages object in desktop/src/i18n.ts" unless body

    body.lines.filter_map do |line|
      match = line.match(/^\s*"(?<key>(?:[^"\\]|\\.)+)"\s*:\s*"(?<value>(?:[^"\\]|\\.)*)"\s*,?\s*$/)
      next if line.strip.empty?
      raise "Unsupported deMessages entry: #{line.strip}" unless match

      Entry.new("desktop/src/i18n.ts", JSON.parse(%("#{match[:key]}")), JSON.parse(%("#{match[:value]}")))
    end
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
