require "rails_helper"
require "json"

RSpec.describe "SDLC Pipeline frontend locales", type: :unit do
  let(:root) { Rails.root.join("plugins/sdlc_pipeline/app/frontend/i18n/locales") }

  it "keeps keys and interpolation tokens aligned" do
    english = JSON.parse(root.join("en/sdlc_pipeline.json").read)
    %w[de la].each do |locale|
      translated = JSON.parse(root.join("#{locale}/sdlc_pipeline.json").read)
      expect(translated.keys).to eq(english.keys)
      english.each do |key, value|
        expect(translated.fetch(key).scan(/{{[^}]+}}/).sort).to eq(value.scan(/{{[^}]+}}/).sort)
      end
    end
  end
end
