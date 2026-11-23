require "rails_helper"
require "json"

RSpec.describe "Coverage frontend locales" do
  let(:locale_root) { Rails.root.join("plugins/syrus_coverage/app/frontend/i18n/locales") }

  def locale(name) = JSON.parse(File.read(locale_root.join(name, "syrus_coverage.json")))

  def interpolation_tokens(value) = value.scan(/{{[^}]+}}/).sort

  it "keeps locale keys and interpolation tokens aligned with English" do
    english = locale("en")

    %w[de la].each do |name|
      translated = locale(name)
      expect(translated.keys).to eq(english.keys)
      english.each do |key, value|
        expect(interpolation_tokens(translated.fetch(key))).to eq(interpolation_tokens(value)), "#{name} tokens differ for #{key}"
      end
    end
  end

  it "carries the card and trend strings the components use" do
    expect(locale("en").keys).to include("coverage_title", "coverage_files_show", "coverage_trend_label", "coverage_trend_aria")
  end
end
