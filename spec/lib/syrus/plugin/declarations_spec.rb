require "rails_helper"

RSpec.describe Syrus::Plugin::Declarations do
  def normalize(point, **attrs) = described_class.normalize!("acme", point, attrs)

  def trigger(**overrides) = { kind: "acme_run", template: "Acme::Workflow", label: "Acme", style: "bg-sky-100" }.merge(overrides)

  def step(**overrides) = { kind: "acme_step", handler: "Acme::Step", label: "Acme", style: "bg-sky-100", agentic: false }.merge(overrides)

  def with_registry
    snapshot = Syrus::PluginRegistry.snapshot
    yield
  ensure
    Syrus::PluginRegistry.restore(snapshot)
  end

  it "names the same points as the plugin DSL and the legacy extension points" do
    expect(described_class::POINTS).to eq(Syrus::PluginApi::Definition::DECLARATION_POINTS)
    expect(described_class::POINTS - Syrus::PluginRegistry::EXTENSION_POINTS).to be_empty
  end

  describe "entry shapes track the core kind tables" do
    it "accepts exactly the attributes core can build an entry from" do
      expect(described_class::TRIGGER_KEYS - Workflow::TriggerKind::Entry.members).to be_empty
      expect(Workflow::TriggerKind::Entry.members - described_class::TRIGGER_KEYS)
        .to contain_exactly(:diff_review_labeler)
      expect(described_class::STEP_KEYS - Step::Kind::Entry.members).to be_empty
      expect(Step::Kind::Entry.members - described_class::STEP_KEYS).to contain_exactly(:dynamic_required_mcp_tools)
      expect(described_class::JOB_KEYS).to match_array(Job::Kind::Entry.members)
      expect(described_class::PROBLEM_KEYS).to match_array(Problem::Kind::Entry.members - [ :label ] + [ :label ])
    end
  end

  describe "workflow_kinds" do
    it "normalizes and freezes valid data" do
      entry = normalize(:workflow_kinds, trigger_kinds: [ trigger ], step_kinds: [ step ],
        job_kinds: [ { kind: "acme", issueless: true } ], work_definitions: [ "Acme::WorkDefinition" ])

      expect(entry[:trigger_kinds].first).to include(kind: "acme_run")
      expect(entry).to be_frozen
      expect(entry[:step_kinds].first).to be_frozen
    end

    it "rejects a malformed kind with the plugin and field named" do
      expect { normalize(:workflow_kinds, trigger_kinds: [ trigger(kind: "Bad Kind") ]) }
        .to raise_error(described_class::InvalidDeclaration, /acme: trigger_kinds entry kind must be a lowercase identifier/)
    end

    it "rejects unknown and missing keys" do
      expect { normalize(:workflow_kinds, trigger_kinds: [ trigger(bogus: 1) ]) }
        .to raise_error(described_class::InvalidDeclaration, /"acme_run" has unknown key\(s\) bogus/)
      expect { normalize(:workflow_kinds, step_kinds: [ step.except(:handler) ]) }
        .to raise_error(described_class::InvalidDeclaration, /"acme_step" is missing required key\(s\) handler/)
      expect { normalize(:workflow_kinds, bogus: []) }
        .to raise_error(described_class::InvalidDeclaration, /workflow_kinds has unknown key\(s\) bogus/)
    end

    it "rejects a duplicate kind and a non-data value" do
      expect { normalize(:workflow_kinds, step_kinds: [ step, step ]) }
        .to raise_error(described_class::InvalidDeclaration, /declares "acme_step" more than once/)
      expect { normalize(:workflow_kinds, step_kinds: [ step(handler: Object) ]) }
        .to raise_error(described_class::InvalidDeclaration, /must be plain data.*got Class/)
      expect { normalize(:workflow_kinds, step_kinds: [ step(dynamic_required_mcp_tools: -> { }) ]) }
        .to raise_error(described_class::InvalidDeclaration, /unknown key/)
    end

    it "rejects work definitions that are not constant names" do
      expect { normalize(:workflow_kinds, work_definitions: [ "not a constant" ]) }
        .to raise_error(described_class::InvalidDeclaration, /work_definitions must be a constant name string/)
    end
  end

  describe "job_origin" do
    it "accepts a key with optional behavior and icon" do
      expect(normalize(:job_origin, key: "nightly", provider: "Acme::Origin", icon: "moon"))
        .to eq(key: "nightly", provider: "Acme::Origin", icon: "moon")
      expect(normalize(:job_origin, key: "nightly")).to include(provider: nil)
    end

    it "rejects a bad key, provider and unknown key" do
      expect { normalize(:job_origin, key: "Nightly") }.to raise_error(described_class::InvalidDeclaration, /job_origin key must match/)
      expect { normalize(:job_origin, key: "nightly", provider: "x") }.to raise_error(described_class::InvalidDeclaration, /provider must be a constant name/)
      expect { normalize(:job_origin, key: "nightly", label: "x") }.to raise_error(described_class::InvalidDeclaration, /unknown key\(s\) label/)
    end
  end

  describe "slug_type" do
    let(:valid) { { prefix: "DOC", display_label: "Doc", resolver: "Acme::Resolver" } }

    it "defaults the flags" do
      expect(normalize(:slug_type, **valid)).to include(copyable: true, linkable: true, preview_available: false, client_path: nil)
    end

    it "rejects a bad prefix, label, resolver, flag and link template" do
      expect { normalize(:slug_type, **valid, prefix: "doc") }.to raise_error(described_class::InvalidDeclaration, /prefix must be upper-case/)
      expect { normalize(:slug_type, **valid, display_label: " ") }.to raise_error(described_class::InvalidDeclaration, /display_label must be a non-empty string/)
      expect { normalize(:slug_type, **valid.except(:resolver)) }.to raise_error(described_class::InvalidDeclaration, /resolver must be a constant name/)
      expect { normalize(:slug_type, **valid, copyable: "yes") }.to raise_error(described_class::InvalidDeclaration, /copyable must be true or false/)
      expect { normalize(:slug_type, **valid, client_path: "docs/:id") }.to raise_error(described_class::InvalidDeclaration, /client_path must start with "\/"/)
    end
  end

  describe "problem_provider" do
    let(:kind) { { code: "acme.stale", scope: "run", retryable: true, default_remediation: "restart_workflow" } }

    it "accepts namespaced kinds" do
      expect(normalize(:problem_provider, namespace: "acme", kinds: [ kind ])[:kinds].first).to include(code: "acme.stale")
    end

    it "rejects a bad namespace, a code outside it and missing keys" do
      expect { normalize(:problem_provider, namespace: "Acme", kinds: []) }.to raise_error(described_class::InvalidDeclaration, /namespace must match/)
      expect { normalize(:problem_provider, namespace: "acme", kinds: [ kind.merge(code: "other.stale") ]) }
        .to raise_error(described_class::InvalidDeclaration, /must start with its namespace "acme\."/)
      expect { normalize(:problem_provider, namespace: "acme", kinds: [ kind.except(:scope) ]) }
        .to raise_error(described_class::InvalidDeclaration, /missing required key\(s\) scope/)
    end
  end

  describe "repository_configuration" do
    let(:valid) { { key: "acme.review", provider: "Acme::Config" } }

    it "defaults the schema version and legacy keys" do
      expect(normalize(:repository_configuration, **valid)).to include(schema_version: 1, legacy_keys: [])
    end

    it "requires a namespaced key owned by the plugin" do
      expect { normalize(:repository_configuration, **valid, key: "review") }.to raise_error(described_class::InvalidDeclaration, /must be namespaced/)
      expect { normalize(:repository_configuration, **valid, key: "other.review") }.to raise_error(described_class::InvalidDeclaration, /owner namespace "acme\."/)
      expect { normalize(:repository_configuration, **valid, schema_version: 0) }.to raise_error(described_class::InvalidDeclaration, /schema_version must be a positive integer/)
      expect { normalize(:repository_configuration, **valid, legacy_keys: [ "Bad Key" ]) }.to raise_error(described_class::InvalidDeclaration, /legacy_keys must be identifiers/)
      expect { normalize(:repository_configuration, key: "acme.review") }.to raise_error(described_class::InvalidDeclaration, /provider must be a constant name/)
    end
  end

  describe "step_environment" do
    it "accepts forwarded names, a computing class, or both" do
      expect(normalize(:step_environment, forwarded_env_keys: %w[ACME_TOKEN ACME_TOKEN])[:forwarded_env_keys]).to eq(%w[ACME_TOKEN])
      expect(normalize(:step_environment, extra_env: "Acme::Env")).to include(extra_env: "Acme::Env")
    end

    it "rejects lowercase names, an empty declaration and a bad class" do
      expect { normalize(:step_environment, forwarded_env_keys: %w[acme_token]) }.to raise_error(described_class::InvalidDeclaration, /forwarded_env_keys must be ENV names/)
      expect { normalize(:step_environment) }.to raise_error(described_class::InvalidDeclaration, /must declare forwarded_env_keys or an extra_env class/)
      expect { normalize(:step_environment, extra_env: "nope") }.to raise_error(described_class::InvalidDeclaration, /extra_env must be a constant name/)
    end
  end

  describe "worker_capability_probe" do
    let(:valid) { { dimension: "runtime", token: "acme_vm", probe: "Acme::Probe" } }

    it "defaults the diagnostic key to the token" do
      expect(normalize(:worker_capability_probe, **valid)).to include(diagnostic_key: "acme_vm")
    end

    it "rejects a bad token, dimension and probe" do
      expect { normalize(:worker_capability_probe, **valid, token: "Acme VM") }.to raise_error(described_class::InvalidDeclaration, /token must match/)
      expect { normalize(:worker_capability_probe, **valid, dimension: nil) }.to raise_error(described_class::InvalidDeclaration, /dimension must be an identifier/)
      expect { normalize(:worker_capability_probe, **valid.except(:probe)) }.to raise_error(described_class::InvalidDeclaration, /probe must be a constant name/)
    end

    it "reports a dimension core does not know as a registration finding, not an exception" do
      with_registry do
        Syrus::PluginRegistry.register(name: "acme_probe", declarations: {
          worker_capability_probe: [ valid.merge(dimension: "weather") ]
        })

        errors = Syrus::PluginRegistry.all_plugins.find { |manifest| manifest.name == "acme_probe" }.validation_errors
        expect(errors.join).to include("unknown dimension \"weather\"")
      end
    end
  end

  it "rejects a point it does not declare" do
    expect { normalize(:removed_point, anything: 1) }.to raise_error(described_class::InvalidDeclaration, /unknown manifest declaration :removed_point/)
  end

  describe "registration" do
    it "drops an invalid declaration into the manifest's validation errors and keeps the valid ones" do
      with_registry do
        Syrus::PluginRegistry.register(name: "acme_mixed", declarations: {
          job_origin: [ { key: "Bad Key" }, { key: "good" } ],
          removed_point: [ { x: 1 } ]
        })

        manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == "acme_mixed" }
        expect(manifest.declarations[:job_origin].map { |entry| entry[:key] }).to eq(%w[good])
        expect(manifest.validation_errors.join).to include("job_origin key must match", "unknown manifest declaration :removed_point")
        expect(Syrus::PluginRegistry.health.status("acme_mixed").state).to eq(:degraded)
      end
    end
  end

  describe "manifest introspection" do
    it "lists every declaration without resolving any plugin constant" do
      with_registry do
        Syrus::PluginRegistry.register(name: "acme_lazy", declarations: described_class.sanitize("acme_lazy", {
          workflow_kinds: [ { work_definitions: [ "Missing::WorkDefinition" ], job_kinds: [ { kind: "acme_lazy_job" } ] } ],
          job_origin: [ { key: "acme_lazy", provider: "Missing::Origin" } ],
          slug_type: [ { prefix: "LAZY", display_label: "Lazy", resolver: "Missing::Resolver", client_path: "/lazy/:id" } ],
          repository_configuration: [ { key: "acme_lazy.cfg", provider: "Missing::Config", legacy_keys: [ "lazy" ] } ],
          step_environment: [ { forwarded_env_keys: %w[LAZY_TOKEN], extra_env: "Missing::Env" } ],
          worker_capability_probe: [ { dimension: "runtime", token: "lazy_vm", probe: "Missing::Probe" } ]
        }).first)

        manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == "acme_lazy" }
        expect(manifest.validation_errors).to eq([])
        expect(manifest.declarations.keys).to match_array(%i[workflow_kinds job_origin slug_type repository_configuration step_environment worker_capability_probe])
        expect(manifest.declarations[:slug_type].first[:resolver]).to eq("Missing::Resolver")

        slug = described_class.providers_for_manifest(manifest, :slug_type).first
        expect(slug.client_metadata).to include(prefix: "LAZY", href_template: "/lazy/:id", type: "lazy")
        expect(described_class.providers_for_manifest(manifest, :job_origin).first.origin_key).to eq("acme_lazy")
        expect(described_class.providers_for_manifest(manifest, :repository_configuration).first).to have_attributes(key: "acme_lazy.cfg", legacy_keys: [ "lazy" ])
        expect(described_class.providers_for_manifest(manifest, :step_environment).first.forwarded_env_keys).to eq(%w[LAZY_TOKEN])
        expect(described_class.providers_for_manifest(manifest, :workflow_kinds).first.job_kinds).to eq([ { kind: "acme_lazy_job" } ])

        # Behavior is loaded only when used, and fails there rather than at parse.
        expect { slug.record_for(1, user: nil) }.to raise_error(NameError, /Missing/)
      end
    end
  end

  describe "the legacy bridge" do
    let(:legacy_origin) do
      Class.new do
        include Syrus::Plugin::JobOrigin
        def self.origin_key = "legacy_origin"
        def self.label(origin_id:, repository: nil) = "legacy #{origin_id}"
      end
    end

    it "answers from a registered provider class and from a declaration through the same lookup" do
      with_registry do
        Syrus::PluginRegistry.register(name: "acme_legacy", provides: { job_origin: legacy_origin })
        Syrus::PluginRegistry.register(name: "acme_declared", declarations: { job_origin: [ { key: "declared_origin" } ] })

        keys = Syrus::PluginRegistry.providers_for(:job_origin).map(&:origin_key)
        expect(keys).to include("legacy_origin", "declared_origin")
        declared = Syrus::PluginRegistry.providers_for(:job_origin).find { |provider| provider.origin_key == "declared_origin" }
        expect(declared.label(origin_id: 7)).to eq("7")
        expect(declared.url(origin_id: 7)).to be_nil
        expect(Syrus::PluginRegistry.plugin_name_for(declared)).to eq("acme_declared")
      end
    end

    it "reports a plugin that declares a point as data and still registers a class for it" do
      with_registry do
        Syrus::PluginRegistry.register(name: "acme_doubled", provides: { job_origin: legacy_origin },
          declarations: { job_origin: [ { key: "doubled" } ] })

        expect(Syrus::PluginRegistry.declaration_duplicate_registrations)
          .to include(plugin: "acme_doubled", extension_point: :job_origin)
      end
    end

    it "withholds a disabled plugin's declarations like it withholds its classes" do
      with_registry do
        Syrus::PluginRegistry.register(name: "acme_off", disableable: true, declarations: { job_origin: [ { key: "off_origin" } ] })
        PluginRecord.find_or_create_by!(name: "acme_off").update!(enabled: false, disableable: true)

        expect(Syrus::PluginRegistry.providers_for(:job_origin).map(&:origin_key)).not_to include("off_origin")
        manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == "acme_off" }
        expect(Syrus::PluginRegistry.manifest_providers_for(manifest, :job_origin).map(&:origin_key)).to eq(%w[off_origin])
      end
    end
  end

  describe "kinds resolve the same way before and after the move" do
    it "builds a core entry from every bundled workflow_kinds declaration" do
      declared = Syrus::PluginRegistry.all_plugins.flat_map do |manifest|
        described_class.providers_for_manifest(manifest, :workflow_kinds)
      end
      expect(declared).not_to be_empty

      declared.each do |provider|
        provider.trigger_kinds.each { |attrs| expect(Workflow::TriggerKind::Entry.new(**attrs).kind).to eq(attrs[:kind]) }
        provider.step_kinds.each { |attrs| expect(Step::Kind::Entry.new(**attrs).kind).to eq(attrs[:kind]) }
        provider.job_kinds.each { |attrs| expect(Job::Kind::Entry.new(**attrs).kind).to eq(attrs[:kind]) }
        provider.work_definitions.each { |definition| expect(definition.ancestors).to include(WorkDefinitions::Base) }
      end
    end

    it "keeps the attributes the legacy provider classes returned" do
      PluginRecord.find_or_create_by!(name: "operator_briefing").update!(enabled: true, disableable: true)
      PluginRecord.find_or_create_by!(name: "agent_insights").update!(enabled: true, disableable: true)

      expect(Step::Kind.by_kind.fetch("briefing_generate_run")).to have_attributes(
        agentic: true, agent_role: AgentRole::WORKFLOW_SUMMARY_TEST_PLAN, required_mcp_tools: %w[submit_briefing_block],
        placement_policy: Step::PlacementPolicy::CONTROL_PLANE
      )
      expect(Step::Kind.by_kind.fetch("agent_insight_run")).to have_attributes(agent_role: AgentRole::AGENT_INSIGHT)
      expect(Workflow::TriggerKind.by_kind.fetch("briefing_dive")).to have_attributes(runtime_role: "child", feedback_kind: nil)
      expect(Job::Kind.values).to include("briefing_generate", "agent_insight")
      expect(WorkDefinitions.for("briefing_dive")).to be_a(OperatorBriefing::DiveWorkDefinition)
    end

    it "keeps core kinds in the core tables, unchanged by plugin declarations" do
      expect(Workflow::TriggerKind::BUILT_IN_ENTRIES.map(&:kind)).to include("initial")
      expect(Step::Kind::BUILT_IN_ENTRIES.map(&:kind)).to include("implement")
      expect(Job::Kind::BUILT_IN_ENTRIES.map(&:kind)).to include("issue")
      expect(Workflow::TriggerKind.by_kind.fetch("initial")).to equal(Workflow::TriggerKind::BUILT_IN_ENTRIES.find { |entry| entry.kind == "initial" })
    end

    it "still refuses a declaration that shadows a core kind" do
      with_registry do
        Syrus::PluginRegistry.register(name: "acme_shadow", declarations: {
          workflow_kinds: [ { job_kinds: [ { kind: "issue" } ] } ]
        })
        Syrus::Installer.sync!

        expect(Job::Kind.entries.count { |entry| entry.kind == "issue" }).to eq(1)
      end
    end
  end

  describe "bundled plugins" do
    it "declare the seven points as data and keep no provider class registered for them" do
      migrated = Syrus::PluginRegistry.all_plugins.flat_map do |manifest|
        described_class::POINTS.select { |point| manifest.declarations[point].present? }
      end.uniq
      expect(migrated).to match_array(described_class::POINTS - %i[problem_provider])

      legacy = Syrus::PluginRegistry.all_plugins.flat_map do |manifest|
        described_class::POINTS.select { |point| Array(manifest.provides[point]).any? }.map { |point| [ manifest.name, point ] }
      end
      expect(legacy).to eq([])
      expect(Syrus::PluginRegistry.declaration_duplicate_registrations).to eq([])
      expect(Syrus::PluginRegistry.all_plugins.flat_map(&:validation_errors).grep(/declaration|declares/)).to eq([])
    end

    it "pins the Coworkers schema version to the declared one" do
      declared = Syrus::PluginRegistry.all_plugins.find { |manifest| manifest.name == "coworkers" }.declarations[:repository_configuration].first
      expect(declared[:schema_version]).to eq(Coworkers::RepositoryConfiguration.schema_version)
    end
  end

  describe "problem_provider kinds" do
    it "register through the same validated registry as a legacy provider" do
      with_registry do
        Syrus::PluginRegistry.register(name: "acme_problems", declarations: {
          problem_provider: [ { namespace: "acme_problems", kinds: [
            { code: "acme_problems.stale", scope: "run", retryable: true, default_remediation: "restart_workflow" }
          ] } ]
        })
        Syrus::Installer.sync!

        expect(Problem::Kind.fetch("acme_problems.stale")).to have_attributes(scope: :run, default_remediation: :restart_workflow)
      end
    end
  end
end
