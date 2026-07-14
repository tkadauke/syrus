require "spec_helper"

RSpec.describe "install.sh" do
  let(:script) { File.read(File.expand_path("../../install.sh", __dir__), encoding: "UTF-8") }

  it "prints compact first-run next steps after Docker startup" do
    # ${port} is defaulted to 3000 right after it's read from .env.
    expect(script).to include('port="${port:-3000}"')
    expect(script).to include('info "Syrus is running at http://localhost:${port}"')
    expect(script).to include('info "Next steps:"')
    expect(script).to include('info "  1. Open http://localhost:${port} and create the first admin account."')
    expect(script).to include('info "  2. Complete /onboarding: GitHub credentials, agent, first repository."')
    expect(script).to include('info "  3. Logs: docker compose -p $PROJECT logs -f web worker   Stop: docker compose -p $PROJECT down"')
    expect(script).to include('info "  4. Read README.md or website docs for next steps."')
  end
end
