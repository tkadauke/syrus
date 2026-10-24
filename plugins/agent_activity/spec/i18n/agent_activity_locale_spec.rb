require "rails_helper"
require "json"

RSpec.describe "Agent Activity frontend locales", type: :unit do
  let(:locale_root) { Rails.root.join("plugins/agent_activity/app/frontend/i18n/locales") }

  def locale(name)
    JSON.parse(File.read(locale_root.join(name, "agent_activity.json")))
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

  it "uses informal German address" do
    expect(locale("de").fetch("description")).to include("die du sehen kannst")
  end
end
