require "rails_helper"
require "json"

RSpec.describe "Whiteboard frontend locales", type: :unit do
  let(:locale_root) { Rails.root.join("plugins/whiteboard/app/frontend/i18n/locales") }

  def locale(name)
    JSON.parse(File.read(locale_root.join(name, "whiteboard.json")))
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

  it "uses informal German and native orthography for results, recovery, and deletion" do
    german = locale("de")

    expect(german).to include(
      "tool_field_height" => "Höhe",
      "tool_field_stroke_width" => "Strichstärke",
      "tool_field_font_size" => "Schriftgröße",
      "tool_field_approx_size" => "Ungefähre Größe",
      "tool_missing_result" => "Das Ergebnis enthält keine Element-ID",
      "tool_missing_result_summary" => "{{action}} gab kein Element zurück",
      "tool_recovery_check_canvas" => "Prüfe vor dem erneuten Versuch, ob die Zeichenfläche teilweise geändert wurde.",
      "tool_elements_added" => "Elemente hinzugefügt",
      "tool_action_deleted_element" => "Element gelöscht",
      "tool_save_snapshot_recovery" => "Prüfe, ob die Zeichenfläche gültige Elemente enthält, und versuche es erneut."
    )
    expect(german.values.join("\n")).not_to match(/\b(?:Sie|Ihnen|Ihr(?:e[mnrs]?|en)?)\b/)
  end

  it "repairs Latin adverb spelling without changing plugin terminology" do
    expect(locale("la")).to include(
      "tool_auto_saved_as" => "Automatice servatum ut",
      "tool_saved_snapshot" => "Snapshot servatum",
      "tool_cleared_canvas" => "Canvas purgata"
    )
  end
end
