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
  DEBT_BASELINE = Set.new.freeze

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
    relative = Pathname(path).absolute? ? Pathname(path).relative_path_from(Rails.root).to_s : path.to_s
    body = contents[/\bconst deMessages\s*=\s*\{(?<body>.*?)\n\}\s+satisfies\s+Record<DesktopMessageKey, string>/m, :body]
    raise "Could not find the bounded deMessages object in desktop/electron/i18nCatalog.ts" unless body

    entries = body.scan(/"(?<key>(?:[^"\\]|\\.)+)"\s*:\s*(?:"(?<double>(?:[^"\\]|\\.)*)"|'(?<single>(?:[^'\\]|\\.)*)')\s*,?/m).map do |key, double, single|
      parsed_value = double ? JSON.parse(%("#{double}")) : single.gsub("\\'", "'").gsub("\\n", "\n")
      Entry.new(relative, JSON.parse(%("#{key}")), parsed_value)
    end
    raise "Could not parse every deMessages entry in desktop/electron/i18nCatalog.ts" unless entries.size == body.scan(/^\s*"(?:[^"\\]|\\.)+"\s*:/).size

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
