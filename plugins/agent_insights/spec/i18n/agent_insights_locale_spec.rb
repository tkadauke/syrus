require "rails_helper"
require "json"

RSpec.describe "Agent Insights frontend locales", type: :unit do
  let(:locale_root) { Rails.root.join("plugins/agent_insights/app/frontend/i18n/locales") }

  def locale(name)
    JSON.parse(File.read(locale_root.join(name, "agent_insights.json")))
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
        expect(interpolation_tokens(translated.fetch(key))).to eq(interpolation_tokens(value)), "#{name}.#{key}"
      end
    end
  end

  it "translates the previously English-only insight table labels" do
    expect(locale("de")).to include("col_category" => "Kategorie", "nav_insights" => "Einblicke")
    expect(locale("la")).to include("col_category" => "Categoria", "nav_insights" => "Perspectivae")
  end
end
