require "rails_helper"

RSpec.describe PluginRouteDispatch do
  subject(:dispatcher) do
    Class.new do
      include PluginRouteDispatch

      attr_reader :rendered_error, :rendered_json, :routed

      def request = :request

      def dispatch_plugin_route!(route)
        @routed = route
      end

      def render_error(code, message, status:)
        @rendered_error = { code: code, message: message, status: status }
      end

      def render(json:, status:)
        @rendered_json = { json: json, status: status }
      end
    end.new
  end

  let(:controller_prefix) { "api/v1/app/" }

  it "dispatches the enabled route resolved for the requested API namespace" do
    route = instance_double("PluginRoute")
    allow(PluginRouteResolver).to receive(:find).with(:request, controller_prefix: controller_prefix).and_return(route)
    allow(PluginRouteResolver).to receive(:find_disabled)

    dispatcher.send(:dispatch_plugin_route_for!, controller_prefix: controller_prefix)

    expect(dispatcher.routed).to equal(route)
    expect(PluginRouteResolver).not_to have_received(:find_disabled)
  end

  it "renders the standard disabled response for a disabled plugin route" do
    disabled_route = instance_double("PluginRoute", plugin_name: "design_docs")
    allow(PluginRouteResolver).to receive(:find).and_return(nil)
    allow(PluginRouteResolver).to receive(:find_disabled).with(:request, controller_prefix: controller_prefix).and_return(disabled_route)

    dispatcher.send(:dispatch_plugin_route_for!, controller_prefix: controller_prefix)

    expect(dispatcher.rendered_error).to include(code: "plugin_disabled", status: :not_found)
  end

  it "preserves legacy disabled response shapes" do
    disabled_route = instance_double("PluginRoute", plugin_name: "tailscale")
    allow(PluginRouteResolver).to receive(:find).and_return(nil)
    allow(PluginRouteResolver).to receive(:find_disabled).and_return(disabled_route)

    dispatcher.send(:dispatch_plugin_route_for!, controller_prefix: controller_prefix)

    expect(dispatcher.rendered_json).to eq(json: { error: "tailscale_plugin_disabled" }, status: :not_found)
  end

  it "renders not_found when no enabled or disabled route matches" do
    allow(PluginRouteResolver).to receive(:find).and_return(nil)
    allow(PluginRouteResolver).to receive(:find_disabled).and_return(nil)

    dispatcher.send(:dispatch_plugin_route_for!, controller_prefix: controller_prefix)

    expect(dispatcher.rendered_error).to include(code: "not_found", status: :not_found)
  end
end
