module Evals
  # A scenario bakes "pressure" into the initial prompt/context handed to a
  # one-shot agent invocation (Syrus's ClaudeInvocation/CodexInvocation calls
  # are non-interactive, so there's no live back-and-forth to apply pressure
  # within — see evals/README.md). Loaded from evals/scenarios/<slug>/scenario.yml.
  Scenario = Struct.new(
    :slug, :name, :target, :description, :skill,
    :issue_title, :issue_body, :rebase_context,
    :rubric, :fixture_dir, :setup_script,
    :max_turns, :timeout_seconds, :history_ancestor_ref,
    keyword_init: true
  ) do
    def prompt
      case skill
      when "implement" then implement_prompt
      when "rebase"     then rebase_prompt
      else raise ArgumentError, "scenario #{slug.inspect}: unknown skill #{skill.inspect} (expected \"implement\" or \"rebase\")"
      end
    end

    private

    def implement_prompt
      issue = Struct.new(:title, :body).new(issue_title, issue_body)
      Prompts::Implement.new(issue: issue).to_s
    end

    def rebase_prompt
      Prompts::Rebase.new(
        repo_slug: rebase_context.fetch("repo_slug"),
        branch_name: rebase_context.fetch("branch_name"),
        base_branch: rebase_context.fetch("base_branch"),
        pr_number: rebase_context.fetch("pr_number")
      ).to_s
    end
  end

  module Scenarios
    ROOT = File.expand_path("../../scenarios", __dir__).freeze

    def self.root = ROOT

    def self.slugs
      Dir.children(ROOT).select { |entry| File.directory?(File.join(ROOT, entry)) }.sort
    end

    def self.all
      slugs.map { |slug| load(slug) }
    end

    def self.load(slug)
      dir = File.join(ROOT, slug)
      yml_path = File.join(dir, "scenario.yml")
      raise ArgumentError, "no scenario found at evals/scenarios/#{slug} (missing scenario.yml)" unless File.exist?(yml_path)

      data = YAML.safe_load_file(yml_path, permitted_classes: [ Integer ])
      issue = data.fetch("issue")
      fixture_dir = File.join(dir, "fixture_repo")
      setup_script = File.join(dir, "setup.rb")

      Scenario.new(
        slug: slug,
        name: data.fetch("name", slug),
        target: data.fetch("target"),
        description: data.fetch("description", "").to_s.strip,
        skill: data.fetch("skill").to_s,
        issue_title: issue.fetch("title"),
        issue_body: issue.fetch("body").to_s.strip,
        rebase_context: data["rebase"],
        rubric: data.fetch("rubric").to_s.strip,
        fixture_dir: (Dir.exist?(fixture_dir) ? fixture_dir : nil),
        setup_script: (File.exist?(setup_script) ? setup_script : nil),
        max_turns: data.fetch("max_turns", 40).to_i,
        timeout_seconds: data.fetch("timeout_seconds", 900).to_i,
        # Git ref/SHA the agent's final HEAD must still descend from.
        # Defaults (nil) to the fixture workspace's pre-run HEAD -- the
        # right invariant for `implement` scenarios ("don't orphan
        # history"). `rebase` scenarios rewrite commits onto a new base,
        # so they set this explicitly to the base branch ref instead.
        history_ancestor_ref: data["history_ancestor_ref"]
      )
    end
  end
end
