require "rails_helper"
require "json"

RSpec.describe "Admin MySQL frontend locales", type: :unit do
  let(:locale_root) { Rails.root.join("plugins/admin_mysql/app/frontend/i18n/locales") }

  def locale(name)
    JSON.parse(File.read(locale_root.join(name, "admin_mysql.json")))
  end

  it "keeps locale keys and interpolation tokens aligned with English" do
    english = locale("en")

    %w[de la].each do |name|
      translated = locale(name)
      expect(translated.keys).to eq(english.keys)
      english.each do |key, value|
        expect(translated.fetch(key).scan(/{{[^}]+}}/).sort).to eq(value.scan(/{{[^}]+}}/).sort),
          "#{name} interpolation tokens differ for #{key}"
      end
    end
  end

  it "uses native German orthography and describes redaction as masking" do
    expect(locale("de")).to include(
      "confirm_kill_query" => "Aktuelle Abfrage für MySQL-Thread {{id}} beenden? Die Verbindung bleibt offen.",
      "counters_heading" => "InnoDB- und Abfragezähler",
      "tool_full_redacted_statement" => "Vollständige maskierte Anweisung",
      "tool_redacted_statement" => "Maskierte Anweisung",
      "tool_running" => "Läuft"
    )
  end
end
