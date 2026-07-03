# Adds any TojTests/*.swift not yet in the project to the TojTests target.
# (The app's Toj/ folder is a synchronized group — new files join automatically.
# TojTests is a classic group, so test files must be registered; run this after
# creating a new test file: `GEM_HOME=$(brew --prefix cocoapods)/libexec $(brew --prefix ruby)/bin/ruby scripts/add_test_files.rb`)
require 'xcodeproj'

project = Xcodeproj::Project.open(File.expand_path('../Toj.xcodeproj', __dir__))
test = project.targets.find { |t| t.name == 'TojTests' } or abort 'TojTests target not found'
grp = project.main_group['TojTests'] || project.main_group.new_group('TojTests', 'TojTests')
existing = grp.files.map { |f| File.basename(f.path.to_s) }

added = []
Dir[File.expand_path('../TojTests/*.swift', __dir__)].sort.each do |file|
  base = File.basename(file)
  next if existing.include?(base)
  ref = grp.new_file(base)
  test.add_file_references([ref])
  added << base
end

project.save
puts added.empty? ? 'nothing to add' : "added: #{added.join(', ')}"
