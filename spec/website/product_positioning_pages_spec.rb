# frozen_string_literal: true

require "spec_helper"

RSpec.describe "website product positioning pages" do
  let(:pages_root) { File.expand_path("../../website/src/pages", __dir__) }
  let(:home) { File.read(File.join(pages_root, "index.md")) }
  let(:what_is_syrus) { File.read(File.join(pages_root, "what-is-syrus.md")) }
  let(:why_use_syrus) { File.read(File.join(pages_root, "why-use-syrus.md")) }
  let(:normalized_what_is_syrus) { what_is_syrus.gsub(/\s+/, " ") }
  let(:normalized_why_use_syrus) { why_use_syrus.gsub(/\s+/, " ") }

  it "links the explanatory pages from the home page" do
    expect(home).to include("[What is Syrus?](/what-is-syrus)")
    expect(home).to include("[Why use Syrus?](/why-use-syrus)")
  end

  it "explains what Syrus is using current product terminology" do
    expect(what_is_syrus).to include("title: What is Syrus?")
    expect(normalized_what_is_syrus).to include("self-hosted automation harness for agentic coding work")
    expect(normalized_what_is_syrus).to include("turns GitHub issues, PR feedback, scheduled tasks, retries, and rebases into controlled agent runs")
    expect(normalized_what_is_syrus).to include("A **Job** is the long-lived thread of work.")
    expect(normalized_what_is_syrus).to include("A **Workflow** is one attempt to move that Job forward.")
    expect(normalized_what_is_syrus).to include("A **Step** is one stage in the Workflow")
    expect(normalized_what_is_syrus).to include("A **Run** is one execution attempt for a Step")
  end

  it "helps visitors decide whether Syrus fits their workflow" do
    expect(why_use_syrus).to include("title: Why use Syrus?")
    expect(normalized_why_use_syrus).to include("If those are not your problems, Syrus may be more machinery than you need.")
    expect(normalized_why_use_syrus).to include("Syrus is strongest for bounded GitHub work")
    expect(normalized_why_use_syrus).to include("Syrus may not fit if:")
    expect(normalized_why_use_syrus).to include("you only want interactive local coding help")
    expect(normalized_why_use_syrus).to include("your team does not use GitHub issues and pull requests as the workflow")
  end
end
