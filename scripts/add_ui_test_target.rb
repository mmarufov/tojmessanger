# Adds the production-like local-first UI test target without touching the app target's
# synchronized source group. Safe to rerun after project regeneration.
require 'xcodeproj'

project_path = File.expand_path('../Toj.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
app = project.targets.find { |target| target.name == 'Toj' } or abort 'Toj target not found'

ui_tests = project.targets.find { |target| target.name == 'TojUITests' }
unless ui_tests
  ui_tests = project.new_target(:ui_test_bundle, 'TojUITests', :ios, '26.0')
  ui_tests.add_dependency(app)
end

ui_tests.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings['PRODUCT_NAME'] = 'TojUITests'
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.toj.TojUITests'
  settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  settings['SWIFT_VERSION'] = '5.0'
  settings['IPHONEOS_DEPLOYMENT_TARGET'] = '26.0'
  settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
  settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  settings['TEST_TARGET_NAME'] = 'Toj'
  settings['CODE_SIGN_STYLE'] = 'Automatic'
  settings['SWIFT_ENABLE_EXPLICIT_MODULES'] = 'NO'
end

group = project.main_group['TojUITests'] || project.main_group.new_group('TojUITests', 'TojUITests')
existing = group.files.map { |file| File.basename(file.path.to_s) }
Dir[File.expand_path('../TojUITests/*.swift', __dir__)].sort.each do |source|
  basename = File.basename(source)
  next if existing.include?(basename)
  reference = group.new_file(basename)
  ui_tests.add_file_references([reference])
end

project.save
puts "TojUITests target: #{ui_tests.uuid}"
