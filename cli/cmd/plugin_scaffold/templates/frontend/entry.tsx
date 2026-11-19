import React from "react"
import { registerPluginContribution } from "@syrus/plugin-sdk"
import "./style.css"

const AdminExample = () => React.createElement("section", { className: "{{PLUGIN_NAME}}-panel" }, "{{DISPLAY_NAME}}")
registerPluginContribution("admin_page", "{{PLUGIN_NAME}}", "AdminExample", { default: AdminExample })
