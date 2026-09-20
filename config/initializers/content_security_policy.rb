# Be sure to restart your server when you modify this file.
#
# The React SPA renders agent-authored, chat, and repository-derived content
# (PR diffs, issue bodies, chat messages, GitHub markdown) — any of that
# becoming injectable script would be a stored-XSS vector regardless of
# hosting model, so a real policy applies even on a single-operator,
# firewalled instance. script-src is the directive that matters most here;
# the others are set to reasonably tight, non-breaking defaults.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    # 'wasm-unsafe-eval' only permits instantiating WebAssembly modules (e.g.
    # Shiki's oniguruma WASM regex engine for diff/code syntax highlighting);
    # it does not grant JS `eval`/`new Function` the way 'unsafe-eval' does,
    # so it doesn't weaken the stored-XSS protection this policy exists for.
    policy.script_src  :self, :wasm_unsafe_eval
    # Tailwind-generated classes plus a modest number of React components set
    # inline `style={{...}}`; most of that goes through the CSSOM (exempt from
    # CSP either way), but 'unsafe-inline' keeps any literal style="" markup
    # working without hash/nonce bookkeeping for a much lower-severity surface
    # than script-src.
    policy.style_src   :self, :unsafe_inline
    # avatar_url is an operator/user-supplied URL (Account Settings), not
    # restricted to a known set of hosts, so img-src has to allow arbitrary
    # remote hosts; data:/blob: cover pasted screenshots and generated
    # previews (BugReportButton, diff review attachments).
    policy.img_src     :self, :data, :blob, :http, :https
    policy.font_src    :self, :data
    policy.object_src  :none
    policy.base_uri    :self
    policy.form_action :self
    # No other site should be able to iframe Syrus (clickjacking).
    policy.frame_ancestors :self
    # Action Cable connects same-origin (createConsumer() with no URL) —
    # :self also matches its ws(s):// upgrade of the current origin.
    policy.connect_src :self

    # Preview panels (mockups, HTML previews surfaced in chat) render inside
    # an iframe pointing at their own preview-panel-<id>.<base domain>
    # origin; PreviewProxyMiddleware serves that origin directly, ahead of
    # the app, with its own deliberately permissive CSP for the arbitrary
    # generated content it hosts (see app/middleware/preview_proxy_middleware.rb)
    # and never reaches this policy. This app's own policy just needs to
    # allow the SPA to *embed* that sibling origin.
    preview_base_domain = ENV.fetch("SYRUS_PREVIEW_BASE_DOMAIN", "lvh.me")
    policy.frame_src :self, "https://*.#{preview_base_domain}", "http://*.#{preview_base_domain}"
  end

  # Generate a per-request nonce for permitted inline scripts. The SPA
  # layout's anti-flash theme-detection <script> (app/views/layouts/spa.html.erb)
  # carries this nonce explicitly; javascript_include_tag/stylesheet_link_tag
  # output gets it automatically via content_security_policy_nonce_auto.
  # session.id is the value Rails' own guide suggests, but it's blank until
  # something actually reads/writes the session — the signed-out landing
  # page never does, which would leave the theme script with an empty,
  # non-matching nonce. A fresh random value per request has no such gap.
  config.content_security_policy_nonce_generator = ->(request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w[script-src]
  config.content_security_policy_nonce_auto = true
end
