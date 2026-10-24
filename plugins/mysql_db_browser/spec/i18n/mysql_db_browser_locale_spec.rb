require "rails_helper"
require "json"

RSpec.describe "MySQL DB Browser frontend locales", type: :unit do
  let(:locale_root) { Rails.root.join("plugins/mysql_db_browser/app/frontend/i18n/locales") }

  def locale(name)
    JSON.parse(File.read(locale_root.join(name, "mysql_db_browser.json")))
  end

  def interpolation_tokens(value)
    value.scan(/{{[^}]+}}/).sort
  end

  it "keeps locale keys, plural pairs, and interpolation tokens aligned with English" do
    english = locale("en")

    %w[de la].each do |name|
      translated = locale(name)
      expect(translated.keys).to eq(english.keys)

      english.each do |key, value|
        expect(interpolation_tokens(translated.fetch(key))).to eq(interpolation_tokens(value)),
          "#{name} interpolation tokens differ for #{key}"
      end

      english.keys.grep(/_one\z/).each do |one_key|
        expect(translated).to have_key(one_key.sub(/_one\z/, "_other"))
      end
    end
  end

  it "uses informal German and native orthography in tool-card copy" do
    german = locale("de")

    expect(german).to include(
      "empty" => "Noch keine Verbindungen. Füge eine hinzu, um zu beginnen.",
      "select_table_hint" => "Wähle eine Tabelle, um Spalten und Indizes zu sehen.",
      "tool_truncated_notice" => "{{label}} gekürzt -- Grenze die Abfrage für eine vollständige Ansicht ein.",
      "tool_no_connections_agentic" => "Für Agenten sind keine Verbindungen verfügbar. Aktiviere den Agentenzugriff für eine DB-Browser-Verbindung, um MySQL-Werkzeuge zu verwenden."
    )
    expect(german.values.join("\n")).not_to match(/\b(?:Sie|Ihnen|Ihr(?:e[mnrs]?|en)?)\b/)
  end
end
