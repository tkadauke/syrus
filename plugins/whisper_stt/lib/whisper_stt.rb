module WhisperStt
  extend Syrus::PluginApi

  syrus_plugin "whisper_stt" do
    experimental true
    display_name "Whisper speech-to-text"
    description "Runs a whisper.cpp daemon for opt-in backend speech transcription."
    long_description "Whisper speech-to-text runs whisper.cpp's whisper-server as a Plugin Runtime managed service. It keeps the model loaded in a sidecar container and exposes a health-checked HTTP daemon for backend batch chat dictation.\n\nEnable it when an installation should offer local backend batch transcription through whisper.cpp. It is disabled by default because it runs a native model service and requires Plugin Runtime."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/whisper_stt.svg"
    author "Thomas Kadauke"
    category "tooling"
    default_enabled false
    disableable true
    depends_on [ "plugin_runtime" ]
    provides "plugin_runtime:service" => "WhisperStt::RuntimeService",
             speech_to_text_provider: "WhisperStt::Provider"
  end
end
