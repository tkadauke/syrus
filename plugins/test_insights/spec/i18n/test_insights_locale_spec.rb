require "rails_helper"
require "json"

RSpec.describe "Test Insights frontend locales", type: :unit do
  let(:locale_root) { Rails.root.join("plugins/test_insights/app/frontend/i18n/locales") }

  def locale(name)
    JSON.parse(File.read(locale_root.join(name, "test_insights.json")))
  end

  def interpolation_tokens(value)
    value.scan(/{{[^}]+}}/).sort
  end

  it "keeps locale keys, plural pairs, and interpolation tokens aligned with English" do
    english = locale("en")

    %w[de la].each do |name|
      translated = locale(name)
      expect(translated.keys).to eq(english.keys)

      english.each do |key, value|
        expect(interpolation_tokens(translated.fetch(key))).to eq(interpolation_tokens(value)),
          "#{name} interpolation tokens differ for #{key}"
      end

      english.keys.grep(/_one\z/).each do |one_key|
        expect(translated).to have_key(one_key.sub(/_one\z/, "_other"))
      end
    end
  end

  it "uses native German orthography and Lauf for Syrus executions" do
    german = locale("de")

    expect(german).to include(
      "repo_col_run" => "Lauf",
      "run_with_id" => "Lauf {{id}}",
      "repo_back_to_tests" => "Zurück zu Tests",
      "tool_backtrace" => "Stapelrückverfolgung",
      "tool_run_results_summary_one" => "{{failed}} von {{total}} in {{count}} Grader fehlgeschlagen",
      "tool_run_results_summary_other" => "{{failed}} von {{total}} in {{count}} Gradern fehlgeschlagen"
    )
  end

  it "translates Latin instructional prose without changing domain terms" do
    expect(locale("la")).to include(
      "repo_columns_move_up" => "{{label}} sursum move",
      "repo_columns_move_down" => "{{label}} deorsum move",
      "repo_columns_up" => "Sursum",
      "repo_col_run" => "Run"
    )
  end
end
