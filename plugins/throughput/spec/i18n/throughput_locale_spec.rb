require "rails_helper"
require "json"

RSpec.describe "Throughput frontend locales", type: :unit do
  let(:locale_root) { Rails.root.join("plugins/throughput/app/frontend/i18n/locales") }

  def locale(name)
    JSON.parse(File.read(locale_root.join(name, "throughput.json")))
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

  it "uses native German orthography" do
    expect(locale("de")).to include(
      "section_bottlenecks" => "Engpässe",
      "section_latency_capacity" => "Latenz und Kapazität",
      "row_prs_opened" => "PRs geöffnet",
      "row_optimistic_capacity" => "Optimistische Kapazität"
    )
  end
end
