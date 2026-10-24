require "rails_helper"
require "json"

RSpec.describe "Mockups frontend locales", type: :unit do
  let(:locale_root) { Rails.root.join("plugins/mockups/app/frontend/i18n/locales") }

  def locale(name)
    JSON.parse(File.read(locale_root.join(name, "mockups.json")))
  end

  def interpolation_tokens(value)
    value.scan(/{{[^}]+}}/).sort
  end

  it "keeps locale keys and interpolation tokens aligned with English" do
    english = locale("en")

    %w[de la].each do |name|
      translated = locale(name)
      expect(translated.keys).to eq(english.keys)

      english.each do |key, value|
        expect(interpolation_tokens(translated.fetch(key))).to eq(interpolation_tokens(value)),
          "#{name} interpolation tokens differ for #{key}"
      end
    end
  end

  it "translates German panel labels while preserving identifiers" do
    expect(locale("de")).to include(
      "tool_panel_number" => "Bereich Nr. {{id}}",
      "tool_copy_panel_id" => "Bereichs-ID kopieren",
      "tool_panel_id" => "Bereichs-ID",
      "tool_wrote_summary" => "{{path}} geschrieben (Bereich Nr. {{id}})",
      "tool_edited_summary" => "{{path}} bearbeitet (Bereich Nr. {{id}})"
    )
  end
end
