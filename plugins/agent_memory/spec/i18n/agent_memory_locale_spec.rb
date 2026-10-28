require "rails_helper"
require "json"

RSpec.describe "Agent Memory frontend locales", type: :unit do
  let(:locale_root) { Rails.root.join("plugins/agent_memory/app/frontend/i18n/locales") }

  def locale(name)
    JSON.parse(File.read(locale_root.join(name, "agent_memory.json")))
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
        expect(interpolation_tokens(translated.fetch(key))).to eq(interpolation_tokens(value)), "#{name}.#{key}"
      end
      english.keys.grep(/_one\z/).each do |one_key|
        expect(translated).to have_key(one_key.sub(/_one\z/, "_other"))
      end
    end
  end

  it "provides the page label and uses native German orthography and Lauf" do
    expect(locale("de")).to include(
      "aria_memories" => "Erinnerungen",
      "tool_memory_id" => "Erinnerungs-ID",
      "tool_close" => "Schließen",
      "tool_actor_run" => 'Lauf #{{id}}',
      "tool_content_change" => "Inhaltsänderung"
    )
    expect(locale("la").fetch("aria_memories")).to eq("Memoriae")
  end
end
