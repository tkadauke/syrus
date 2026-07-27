// Brand palette: the terracotta of the winged-stylus mark (#b6492e at 600).
// The default Tailwind `blue` scale is remapped onto it so every existing
// `*-blue-*` utility renders the brand accent — one source of truth instead
// of a ~900-occurrence class rename that would conflict with every open
// branch. `terracotta-*` is the preferred name for new code; both names are
// the same scale by design. Keep this in sync with the desktop app's @theme
// block in desktop/src/styles.css.
const terracotta = {
  50: "#faf3ef",
  100: "#f4e2d9",
  200: "#e8c3b3",
  300: "#dba28b",
  400: "#cd7a5c",
  500: "#c05c3f",
  600: "#b6492e",
  700: "#973b25",
  800: "#7a2f1e",
  900: "#632718",
  950: "#361208"
}

module.exports = {
  darkMode: "class",
  content: [
    "./app/assets/tailwind/**/*.css",
    "./app/frontend/**/*.{js,jsx,ts,tsx}",
    "./app/helpers/**/*.rb",
    "./app/views/**/*.{erb,haml,html,slim}",
    "./public/*.html"
  ],
  theme: {
    extend: {
      colors: {
        terracotta,
        blue: terracotta
      },
      // chat_polish: new chat messages ease in. Guarded by motion-safe: at the
      // call site so reduced-motion users never see it.
      keyframes: {
        "chat-message-in": {
          from: { opacity: "0", transform: "translateY(6px)" },
          to: { opacity: "1", transform: "translateY(0)" }
        },
        // Indeterminate progress sweep (backend-update sidebar notice): a
        // one-third-width bar crossing its track. Guarded by motion-safe: at
        // the call site so reduced-motion users see a still bar.
        "progress-indeterminate": {
          from: { transform: "translateX(-100%)" },
          to: { transform: "translateX(300%)" }
        },
        // Drag-over blink: three highlight pulses over 1 second, timed so the
        // navigation fires exactly when the animation ends. Light and dark
        // variants use different highlight colors to match each sidebar theme.
        "drag-blink": {
          "0%, 100%": { backgroundColor: "transparent" },
          "16%": { backgroundColor: "#f3f4f6" },
          "33%": { backgroundColor: "transparent" },
          "50%": { backgroundColor: "#f3f4f6" },
          "66%": { backgroundColor: "transparent" },
          "83%": { backgroundColor: "#f3f4f6" }
        },
        "drag-blink-dark": {
          "0%, 100%": { backgroundColor: "transparent" },
          "16%": { backgroundColor: "#374151" },
          "33%": { backgroundColor: "transparent" },
          "50%": { backgroundColor: "#374151" },
          "66%": { backgroundColor: "transparent" },
          "83%": { backgroundColor: "#374151" }
        }
      },
      animation: {
        "chat-message-in": "chat-message-in 0.25s ease-out both",
        "progress-indeterminate": "progress-indeterminate 1.4s ease-in-out infinite",
        "drag-blink": "drag-blink 1s ease-in-out 1 forwards",
        "drag-blink-dark": "drag-blink-dark 1s ease-in-out 1 forwards"
      }
    }
  }
}
