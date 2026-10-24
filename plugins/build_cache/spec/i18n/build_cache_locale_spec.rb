require "rails_helper"
require "json"

RSpec.describe "Build Cache frontend locales", type: :unit do
  let(:locale_root) { Rails.root.join("plugins/build_cache/app/frontend/i18n/locales") }

  def locale(name)
    JSON.parse(File.read(locale_root.join(name, "build_cache.json")))
  end

  def leaves(value, prefix = nil)
    value.each_with_object({}) do |(key, child), result|
      path = [ prefix, key ].compact.join(".")
      result.merge!(child.is_a?(Hash) ? leaves(child, path) : { path => child })
    end
  end

  it "keeps locale leaves and interpolation tokens aligned with English" do
    english = leaves(locale("en"))

    %w[de la].each do |name|
      translated = leaves(locale(name))
      expect(translated.keys).to match_array(english.keys)
      english.each do |key, value|
        expect(translated.fetch(key).scan(/{{[^}]+}}/).sort).to eq(value.scan(/{{[^}]+}}/).sort),
          "#{name} interpolation tokens differ for #{key}"
      end
    end
  end

  it "translates the filter and result vocabulary in German" do
    german = locale("de").fetch("build_cache")
    expect(german).to include(
      "column_down" => "Nach unten",
      "search" => "Suchen",
      "clear_filters" => "Filter löschen",
      "filter_older_than_days" => "Älter als (Tage)",
      "result_truncated" => "Gekürzt",
      "state_pending" => "Ausstehend"
    )
  end

  it "translates the filter and result vocabulary in Latin" do
    latin = locale("la").fetch("build_cache")
    expect(latin).to include(
      "search" => "Quaere",
      "clear_filters" => "Filtra remove",
      "filter_scope" => "Ambitus",
      "filter_user" => "ID usoris",
      "result_truncated" => "Truncatum",
      "state_pending" => "Pendens"
    )
  end
end
