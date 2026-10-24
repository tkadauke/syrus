require "rails_helper"
require "json"

RSpec.describe "Kubernetes cluster frontend locales", type: :unit do
  let(:locale_root) { Rails.root.join("plugins/k8s_cluster/app/frontend/i18n/locales") }

  def locale(name)
    JSON.parse(File.read(locale_root.join(name, "k8s_cluster.json")))
  end

  def interpolation_tokens(value)
    value.scan(/{{[^}]+}}/).sort
  end

  it "keeps locale keys and interpolation tokens aligned with English" do
    english = locale("en")

    %w[de la].each do |name|
      translated = locale(name)
      expect(translated.keys).to match_array(english.keys)

      english.each do |key, value|
        expect(interpolation_tokens(translated.fetch(key))).to eq(interpolation_tokens(value)),
          "#{name} interpolation tokens differ for #{key}"
      end

      english.keys.grep(/_one\z/).each do |one_key|
        other_key = one_key.sub(/_one\z/, "_other")
        expect(translated).to have_key(other_key), "#{name} is missing plural pair #{other_key}"
      end
    end
  end

  it "uses informal German and translates genuine UI copy" do
    german = locale("de")

    expect(german).to include(
      "empty" => "Noch keine Cluster. Füge einen hinzu, um loszulegen.",
      "tab_workloads" => "Arbeitslasten",
      "tab_logs" => "Protokolle",
      "tab_services" => "Services",
      "action_followup_permission" => "Prüfe, ob Agentenzugriff und Schreibaktionen für den Cluster aktiviert sind."
    )
    expect(german.values.grep(String).join("\n")).not_to match(/\b(?:Sie|Ihnen|Ihr(?:e[mnrs]?|en)?)\b/)
  end

  it "translates Latin prose while retaining Kubernetes and command tokens" do
    latin = locale("la")

    expect(latin).to include(
      "workloads_empty_statefulsets" => "StatefulSets non inventa sunt.",
      "workloads_empty_jobs" => "Jobs non inventa sunt.",
      "workload_kind_statefulsets" => "StatefulSets",
      "kubectl_card_stdout" => "stdout"
    )
  end
end
