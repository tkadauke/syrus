import React from "react"
import { registerPluginContribution } from "@syrus/plugin-sdk"
import "./style.css"

const RelocatablePanel = () => React.createElement("div", { className: "relocatable-plugin" }, "Relocatable plugin")

registerPluginContribution("workspace_tab", "relocatable_plugin", "Relocatable", { default: RelocatablePanel })
