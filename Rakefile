# frozen_string_literal: true

# Migrate

migrate = lambda do |env, version|
  ENV['RACK_ENV'] = env
  require_relative 'db'
  require 'logger'
  Sequel.extension :migration
  DB.loggers << Logger.new($stdout) if DB.loggers.empty?

  Sequel::Migrator.apply(DB, 'migrate', version)
end

desc 'Migrate test database to latest version'
task :test_up do
  migrate.call('test', nil)
end

desc 'Migrate test database all the way down'
task :test_down do
  migrate.call('test', 0)
end

desc 'Migrate test database all the way down and then back up'
task :test_bounce do
  migrate.call('test', 0)
  Sequel::Migrator.apply(DB, 'migrate')
end

desc 'Migrate development database to latest version'
task :dev_up do
  migrate.call('development', nil)
end

desc 'Migrate development database to all the way down'
task :dev_down do
  migrate.call('development', ENV['VERSION'].to_i)
end

desc 'Migrate development database all the way down and then back up'
task :dev_bounce do
  migrate.call('development', 0)
  Sequel::Migrator.apply(DB, 'migrate')
end

desc 'Migrate production database to latest version'
task :prod_up do
  migrate.call('production', nil)
end

# Seed
desc 'Seed initial data: currencies, platforms.'
task :seed do
  require_relative 'seed'
  Seed.run!
end

# Shell

irb = proc do |env|
  ENV['RACK_ENV'] = env
  trap('INT', 'IGNORE')
  dir, base = File.split(FileUtils::RUBY)
  cmd = if base.sub!(/\Aruby/, 'irb')
          File.join(dir, base)
        else
          "#{FileUtils::RUBY} -S irb"
        end
  sh "#{cmd} -r ./models"
end

desc 'Open irb shell in test mode'
task :test_irb do
  irb.call('test')
end

desc 'Open irb shell in development mode'
task :dev_irb do
  irb.call('development')
end

desc 'Open irb shell in production mode'
task :prod_irb do
  irb.call('production')
end

desc 'Open Pry console in development mode'
task :console do
  ENV['RACK_ENV'] = 'development'
  trap('INT', 'IGNORE')
  sh 'bin/console'
end

# Specs

spec = proc do |pattern|
  sh "#{FileUtils::RUBY} #{'-w' if RUBY_VERSION >= '3'} -e 'ARGV.each{|f| require f}' #{pattern}"
end

desc 'Run all specs'
task default: %i[model_spec web_spec]

desc 'Run model specs'
task :model_spec do
  spec.call('./spec/model/*_spec.rb')
end

desc 'Run web specs'
task :web_spec do
  spec.call('./spec/web/*_spec.rb')
end

# Other

desc 'Annotate Sequel models'
task 'annotate' do
  ENV['RACK_ENV'] = 'development'
  require_relative 'models'
  DB.loggers.clear
  require 'sequel/annotate'
  Sequel::Annotate.annotate(Dir['models/**/*.rb'], position: :before)
end
