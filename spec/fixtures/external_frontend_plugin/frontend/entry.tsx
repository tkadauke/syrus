import React from "react"
import { registerPluginContribution } from "@syrus/plugin-sdk"
import "./style.css"

const ExternalFixture = () => React.createElement("div", { className: "external-fixture" }, "External fixture")

registerPluginContribution("workspace_tab", "external_fixture", "Fixture", { default: ExternalFixture })
