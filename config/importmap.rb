# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin "react", to: "https://esm.sh/react@18.3.1"
pin "react/jsx-runtime", to: "https://esm.sh/react@18.3.1/jsx-runtime"
pin "react-dom", to: "https://esm.sh/react-dom@18.3.1"
pin "react-dom/client", to: "https://esm.sh/react-dom@18.3.1/client"
pin "@excalidraw/excalidraw", to: "https://esm.sh/@excalidraw/excalidraw@0.18.1?external=react,react-dom"
pin "html2canvas", to: "https://esm.sh/html2canvas@1.4.1"
pin "mermaid", to: "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs"
pin_all_from "app/javascript/controllers", under: "controllers"
