require "rails_helper"
require "json"

RSpec.describe "Spending Insights frontend locales", type: :unit do
  let(:locale_root) { Rails.root.join("plugins/spending_insights/app/frontend/i18n/locales") }

  def locale(name)
    JSON.parse(File.read(locale_root.join(name, "spending.json")))
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

  it "uses German copy while retaining Syrus domain nouns" do
    expect(locale("de")).to include(
      "aria_insights" => "Ausgabeneinblicke",
      "eyebrow" => "Einblicke",
      "form_start" => "Beginn",
      "col_job" => "Job",
      "entity_epic" => "Epic"
    )
  end
end
