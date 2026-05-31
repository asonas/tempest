require "bundler/gem_tasks"
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/test_*.rb"]
  t.warning = false
end

desc "Type-check the files listed in Steepfile with Steep"
task :steep do
  sh "bundle exec steep check"
end

task default: %i[test steep]
