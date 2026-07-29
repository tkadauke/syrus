import i18n from "i18next"
import { initReactI18next } from "react-i18next"

import enCommon from "./locales/en/common.json"
import enNav from "./locales/en/nav.json"
import enJobs from "./locales/en/jobs.json"
import enEpics from "./locales/en/epics.json"
import enDashboard from "./locales/en/dashboard.json"
import enChat from "./locales/en/chat.json"
import enSettings from "./locales/en/settings.json"
import enAdmin from "./locales/en/admin.json"
import enAuth from "./locales/en/auth.json"
import enLanding from "./locales/en/landing.json"
import enInsights from "./locales/en/insights.json"
import enTours from "./locales/en/tours.json"

import deCommon from "./locales/de/common.json"
import deNav from "./locales/de/nav.json"
import deJobs from "./locales/de/jobs.json"
import deEpics from "./locales/de/epics.json"
import deDashboard from "./locales/de/dashboard.json"
import deChat from "./locales/de/chat.json"
import deSettings from "./locales/de/settings.json"
import deAdmin from "./locales/de/admin.json"
import deAuth from "./locales/de/auth.json"
import deLanding from "./locales/de/landing.json"
import deInsights from "./locales/de/insights.json"
import deTours from "./locales/de/tours.json"

import laCommon from "./locales/la/common.json"
import laNav from "./locales/la/nav.json"
import laJobs from "./locales/la/jobs.json"
import laEpics from "./locales/la/epics.json"
import laDashboard from "./locales/la/dashboard.json"
import laChat from "./locales/la/chat.json"
import laSettings from "./locales/la/settings.json"
import laAdmin from "./locales/la/admin.json"
import laAuth from "./locales/la/auth.json"
import laLanding from "./locales/la/landing.json"
import laInsights from "./locales/la/insights.json"
import laTours from "./locales/la/tours.json"

import { readInitialBootstrap } from "../api/bootstrap"

const bootstrap = readInitialBootstrap()
const storedLocale = bootstrap?.current_user?.locale
const browserLocale = navigator.language?.split("-")[0]
const supportedLocales = ["en", "de", "la"]
const detectedLocale = storedLocale ?? (supportedLocales.includes(browserLocale) ? browserLocale : undefined)

i18n.use(initReactI18next).init({
  lng: detectedLocale,
  fallbackLng: "en",
  defaultNS: "common",
  ns: ["common", "nav", "jobs", "epics", "dashboard", "chat", "settings", "admin", "auth", "landing", "insights", "tours"],
  resources: {
    en: {
      common: enCommon,
      nav: enNav,
      jobs: enJobs,
      epics: enEpics,
      dashboard: enDashboard,
      chat: enChat,
      settings: enSettings,
      admin: enAdmin,
      auth: enAuth,
      landing: enLanding,
      insights: enInsights,
      tours: enTours
    },
    de: {
      common: deCommon,
      nav: deNav,
      jobs: deJobs,
      epics: deEpics,
      dashboard: deDashboard,
      chat: deChat,
      settings: deSettings,
      admin: deAdmin,
      auth: deAuth,
      landing: deLanding,
      insights: deInsights,
      tours: deTours
    },
    la: {
      common: laCommon,
      nav: laNav,
      jobs: laJobs,
      epics: laEpics,
      dashboard: laDashboard,
      chat: laChat,
      settings: laSettings,
      admin: laAdmin,
      auth: laAuth,
      landing: laLanding,
      insights: laInsights,
      tours: laTours
    }
  },
  interpolation: {
    escapeValue: false
  }
})

export default i18n
