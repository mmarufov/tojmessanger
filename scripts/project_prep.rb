# One-time project surgery for Milestone 1: run with `ruby scripts/project_prep.rb`
# - iOS-only, deployment target 17.0 (skeleton doesn't need Liquid Glass / iOS 26)
# - strict concurrency warnings project-wide
# - adds the TojTests unit-test target and a shared Toj scheme that runs it
require 'xcodeproj'
puts "xcodeproj gem #{Xcodeproj::VERSION}"

PROJ = File.expand_path('../Toj.xcodeproj', __dir__)
TEAM = ENV['TOJ_DEVELOPMENT_TEAM']
project = Xcodeproj::Project.open(PROJ)
app = project.targets.find { |t| t.name == 'Toj' } or abort 'Toj target not found'

project.build_configurations.each do |c|
  c.build_settings['SWIFT_STRICT_CONCURRENCY'] = 'complete'
end

app.build_configurations.each do |c|
  bs = c.build_settings
  bs['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  bs['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
  bs['TARGETED_DEVICE_FAMILY'] = '1,2'
  # LibSignalClient does not support explicitly built modules (per its podspec)
  bs['SWIFT_ENABLE_EXPLICIT_MODULES'] = 'NO'
  %w[MACOSX_DEPLOYMENT_TARGET XROS_DEPLOYMENT_TARGET ENABLE_APP_SANDBOX ENABLE_HARDENED_RUNTIME].each { |k| bs.delete(k) }
end

if project.targets.any? { |t| t.name == 'TojTests' }
  puts 'TojTests already exists — skipping target creation'
else
  test = project.new_target(:unit_test_bundle, 'TojTests', :ios, '17.0')
  test.add_dependency(app)
  test.build_configurations.each do |c|
    bs = c.build_settings
    bs['BUNDLE_LOADER'] = '$(TEST_HOST)'
    bs['TEST_HOST'] = '$(BUILT_PRODUCTS_DIR)/Toj.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Toj'
    bs['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.toj.TojTests'
    bs['GENERATE_INFOPLIST_FILE'] = 'YES'
    bs['SWIFT_VERSION'] = '5.0'
    bs['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
    bs['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
    bs['TARGETED_DEVICE_FAMILY'] = '1,2'
    bs['DEVELOPMENT_TEAM'] = TEAM if TEAM && !TEAM.empty?
    bs['CODE_SIGN_STYLE'] = 'Automatic'
    bs['SWIFT_ENABLE_EXPLICIT_MODULES'] = 'NO'
  end

  grp = project.main_group.new_group('TojTests', 'TojTests')
  ref = grp.new_file('TojTests.swift')
  test.add_file_references([ref])
end

project.save
puts 'project saved'

test = project.targets.find { |t| t.name == 'TojTests' }
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.add_test_target(test)
scheme.save_as(PROJ, 'Toj', true)
puts 'shared scheme Toj written (build + test)'
