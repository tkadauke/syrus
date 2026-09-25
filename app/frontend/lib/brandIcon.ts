// Documented source of truth for the favicon/PWA install icon's cache-busting
// version. Production serves public/ files with a 1-year max-age, so a
// rebranded icon.png stays stale in any browser (including the desktop
// shell's web container) that cached a previous backend's copy; bump this
// whenever public/icon*.png changes. Nothing imports this constant — the
// favicon/apple-touch-icon `<link>` tags in app/views/layouts/spa.html.erb
// are server-rendered ERB and hardcode the same `?v=` value directly, since
// ERB can't reference a TS module at render time. spec/assets/brand_icons_spec.rb
// asserts the layout's `?v=` pattern; keep both in sync by hand when bumping.
// The visible in-app Syrus mark no longer renders this PNG at all — see
// SyrusMark in app/frontend/components/SyrusBrand.tsx for the theme-aware
// inline-SVG mark used in the sidebar, mobile header, and first-run welcome.
export const BRAND_ICON_VERSION = 2
