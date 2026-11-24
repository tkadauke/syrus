module Achievements
  # Neutral example fixtures that exercise the registry contract. These are
  # deliberately not the launch catalog: names, artwork, and rarity styling are
  # a later design round, so every key lives under the `example.` namespace.
  module Catalog
    def self.definitions
      [
        Definition.build(
          key: "example.first_job_landed", scope: :user, trigger: "job.landed",
          evaluator: "Achievements::Evaluators::FirstOccurrence", subject_kinds: %i[job],
          category: :landing, rarity: :common,
          presentation: { title_key: "achievements:example.first_job_landed.title",
                          description_key: "achievements:example.first_job_landed.description" }
        ),
        Definition.build(
          key: "example.first_epic_landed", scope: :instance, trigger: "epic.landed",
          evaluator: "Achievements::Evaluators::FirstOccurrence", subject_kinds: %i[epic],
          category: :milestone, rarity: :rare,
          presentation: { title_key: "achievements:example.first_epic_landed.title",
                          description_key: "achievements:example.first_epic_landed.description" }
        ),
        Definition.build(
          key: "example.secret_milestone", scope: :instance, trigger: "job.landed",
          evaluator: "Achievements::Evaluators::Threshold", subject_kinds: %i[job epic],
          category: :milestone, rarity: :legendary, visibility: :hidden,
          presentation: { title_key: "achievements:example.secret_milestone.title" }
        )
      ]
    end
  end
end
