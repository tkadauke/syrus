require "rails_helper"
require "json"

RSpec.describe "Operator briefing frontend locales", type: :unit do
  let(:locale_root) { Rails.root.join("plugins/operator_briefing/app/frontend/i18n/locales") }

  def locale(name)
    JSON.parse(File.read(locale_root.join(name, "operator_briefing.json")))
  end

  it "provides translated German and Latin copy while preserving interpolation tokens" do
    english = locale("en")
    german = locale("de")
    latin = locale("la")

    expect(german).to include(
      "settings_description" => "Rhythmus: {{cadence}}. Sobald die Quellen konfigurierbar sind, kannst du sie hier auswählen.",
      "budget_gate_unenforced" => "Budgetprüfungen sind aktiviert, aber der Kostenschutz wird derzeit nicht durchgesetzt ({{reason}}).",
      "view_job" => "Job ansehen"
    )
    expect(latin).to include(
      "settings_description" => "Frequentia: {{cadence}}. Praeferentiae fontium hic apparebunt cum configurari poterunt.",
      "budget_gate_unenforced" => "Examina sumptuum activa sunt, sed tutela sumptuum nunc non exigitur ({{reason}}).",
      "view_job" => "Job vide"
    )

    english.each_key do |key|
      source_tokens = english.fetch(key).scan(/{{[^}]+}}/).sort
      expect(german.fetch(key).scan(/{{[^}]+}}/).sort).to eq(source_tokens), "German tokens differ for #{key}"
      expect(latin.fetch(key).scan(/{{[^}]+}}/).sort).to eq(source_tokens), "Latin tokens differ for #{key}"
    end
  end
end
