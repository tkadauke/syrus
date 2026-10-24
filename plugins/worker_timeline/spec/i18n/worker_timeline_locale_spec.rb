require "rails_helper"
require "json"

RSpec.describe "Worker Timeline frontend locales", type: :unit do
  let(:locale_root) { Rails.root.join("plugins/worker_timeline/app/frontend/i18n/locales") }

  def locale(name)
    JSON.parse(File.read(locale_root.join(name, "worker_timeline.json")))
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

  it "uses informal German in instructional copy" do
    german = locale("de")
    expect(german).to include(
      "tab_timeline" => "Zeitachse",
      "tab_live_workers" => "Aktive Worker-Prozesse",
      "loading" => "Zeitachse wird geladen…",
      "error_loading" => "Zeitachse konnte nicht geladen werden.",
      "live_metric_slots" => "Ausführungsplätze",
      "live_idle_slot" => "Freier Ausführungsplatz",
      "status_busy" => "Beschäftigt",
      "status_overloaded" => "Überlastet"
    )
    expect(german.fetch("detail_not_started_note")).to eq(
      "Dieser Workflow läuft noch nicht. Zeige auf einen Schritt unten, um den Grund zu sehen."
    )
    expect(german.values.join("\n")).not_to match(/\b(?:Sie|Ihnen|Ihr(?:e[mnrs]?|en)?)\b/)
  end

  it "removes non-terminology English leakage from Latin labels" do
    expect(locale("la")).to include(
      "tab_timeline" => "Linea temporis",
      "tab_live_workers" => "Operarii vivi",
      "live_metric_workers" => "Operarii",
      "live_metric_slots" => "Loca",
      "live_idle_slot" => "Locus otiosus",
      "status_idle" => "Otiosus",
      "status_overloaded" => "Oneratus",
      "unknown_queue_role" => "ordo ignotus",
      "tooltip_workflow" => "WF-{{id}}"
    )
  end
end
