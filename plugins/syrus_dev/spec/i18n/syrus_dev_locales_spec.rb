require "rails_helper"

RSpec.describe "Syrus Dev frontend locales", type: :unit do
  LOCALE_ROOT = Rails.root.join("plugins/syrus_dev/app/frontend/i18n/locales")

  def locale(name)
    JSON.parse(File.read(LOCALE_ROOT.join(name, "syrus_dev.json")))
  end

  def flatten(tree, prefix = nil)
    tree.each_with_object({}) do |(key, value), leaves|
      path = [ prefix, key ].compact.join(".")
      value.is_a?(Hash) ? leaves.merge!(flatten(value, path)) : leaves[path] = value
    end
  end

  it "keeps locale trees and interpolation placeholders aligned with English" do
    english = flatten(locale("en"))

    %w[de la].each do |name|
      translated = flatten(locale(name))
      expect(translated.keys.sort).to eq(english.keys.sort)
      english.each do |key, value|
        expect(translated.fetch(key).scan(/{{\s*([^}\s]+)\s*}}/).flatten.sort).to eq(value.scan(/{{\s*([^}\s]+)\s*}}/).flatten.sort), "#{name}.#{key}"
      end
    end
  end

  it "uses the approved German execution term and translates browser diagnostics" do
    german = locale("de")

    expect(german.dig("artifact_renderers", "meta_run_id")).to eq("Lauf")
    expect(german.dig("performance", "browser_trace_help")).to eq(
      "Zeigt gespeicherte clientseitige Spans und die API-Anfragen, die diesem Browser-Trace zugeordnet sind."
    )
    expect(german.dig("performance", "filter_job_class")).to eq("Job-Klasse")
    expect(flatten(german).values.join("\n")).not_to match(/\b(?:Sie|Ihnen|Ihr(?:e[mnrs]?|en)?)\b/)
  end

  it "removes English prose leakage and repairs Latin grammar" do
    latin = locale("la")

    expect(latin.dig("performance", "browser_trace_help")).to eq(
      "Ostendit spatia a cliente servata et petitiones API huic vestigio navigatoris adiunctas."
    )
    expect(latin.dig("performance", "filter_controller")).to eq("Moderator")
    expect(latin.dig("tool_cards", "discuss", "create_job_requires_prompt")).to end_with("opus creetur.")
  end
end
