require "json"
require "xcodeproj"

directory, app_path, server_url, server_log = ARGV
project = Xcodeproj::Project.new(File.join(directory, "AuthSmoke.xcodeproj"))
target = project.new_target(:ui_test_bundle, "AuthSmoke", :osx, "13.0")
target.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    "CODE_SIGN_IDENTITY" => "-",
    "GENERATE_INFOPLIST_FILE" => "YES",
    "PRODUCT_BUNDLE_IDENTIFIER" => "ai.bb.MacAuthSmoke",
    "SWIFT_VERSION" => "5.0",
  )
end
target.add_file_references([project.main_group.new_file(File.join(__dir__, "macos_auth_test.swift"))])
File.write(
  File.join(directory, "settings.json"),
  JSON.generate(app: app_path, server: server_url, server_log: server_log),
)
target.resources_build_phase.add_file_reference(project.main_group.new_file("settings.json"))
project.save

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(target, target, launch_target: false)
scheme.save_as(project.path, target.name)
