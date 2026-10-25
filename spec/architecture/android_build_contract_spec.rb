# frozen_string_literal: true

RSpec.describe "Android build contract" do
  let(:android_root) { File.expand_path("../../android", __dir__) }

  it "commits an executable Gradle wrapper for isolated grader workers" do
    wrapper = File.join(android_root, "gradlew")
    wrapper_jar = File.join(android_root, "gradle/wrapper/gradle-wrapper.jar")
    properties = File.read(File.join(android_root, "gradle/wrapper/gradle-wrapper.properties"))

    expect(File.executable?(wrapper)).to be(true)
    expect(File.file?(wrapper_jar)).to be(true)
    expect(properties).to include("distributionUrl=https\\://services.gradle.org/distributions/gradle-8.13-bin.zip")
  end
end
