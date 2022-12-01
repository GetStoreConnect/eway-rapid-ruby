# usage:
# release.rb -b develop -v 10.6.2

require 'optparse'
require 'open3'
require 'colorize'
require 'octokit'
require 'netrc'
require 'byebug'

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: release.rb [options]"

  opts.on("-b", "--branch BRANCH", "The branch to build the release from") do |value|
    options[:branch] = value
  end

  opts.on("-v", "--version VERSION", "The new version number") do |value|
    options[:version] = value
  end

  opts.on("-h", "--help", "Prints this help") do
    puts opts
    exit
  end
end.parse!

missing = []
[:branch, :version].each do |opt|
  missing << opt if options[opt].nil?
end

if missing.any?
  puts "\nThe following required arguments are missing:"
  missing.each {|opt| puts "  * #{opt}" }
  puts "\nUse --help for more details"
  puts ""
  exit
end

class Release
  attr_reader :branch, :version, :version_number

  GEM_NAME = "eway_rapid"
  VERSION_FILE = "lib/#{GEM_NAME}/version.rb"
  REPO = "GetStoreConnect/eway-rapid-ruby"
  GEM_FOLDER = "~/#{GEM_NAME}-gems/"
  VERSION_STEPS = %w(major minor patch)

  def initialize(options)
    @branch = options[:branch]
    version = options[:version]
    @version = VERSION_STEPS.include?(version) ? calculate_version(version) : version
    @version_number = "v#{@version}"
    @step = 0
  end

  def release
    checkout_source_branch_and_pull
    update_version_string
    create_release_branch
    generate_release_notes
    bundle_and_commit
    build_gem
    if confirm_release
      puts "Finalising release...".light_green
      complete_release!
    else
      puts "🚫 Release aborted 🚫".light_red
    end
  end

  private

  ## steps

  def checkout_source_branch_and_pull
    step "Checkout branch and pull".light_yellow

    run("git checkout #{branch}")
    verify_cmd("branch is #{branch}", "git branch --show-current", branch)

    run("git pull")
  end

  def update_version_string
    step "Update the version".light_yellow

    check("branch is #{branch}", "git branch --show-current", branch)

    lines = File.readlines(VERSION_FILE)
    line = lines.index {|line| line.start_with?("  VERSION = ") }
    lines[line] = %Q(  VERSION = "#{version}"\n)
    File.open(VERSION_FILE, "w") { |f| f.write(lines.join) }

    verify_cmd("version is set to #{version}", "git diff #{VERSION_FILE}", /\+  VERSION = "#{version}"/)
  end

  def create_release_branch
    step "Create the release branch".light_yellow

    run("git checkout -b #{release_branch}")

    verify_cmd("branch is #{release_branch}", "git branch --show-current", release_branch)
  end

  def generate_release_notes
    step "Generate the release notes".light_yellow

    check("branch is #{release_branch}", "git branch --show-current", release_branch)
    stop("No commits found") if commits.empty?

    changelog = decorate_commits(commits)
    dependabot, updates = changelog.partition {|item| item.include?("dependabot")}

    release_notes = <<~NOTES
      @channel

      *Gem #{gem_filename} released*

      Branch: *#{branch}*

      Updates:
      #{updates.sort.join("\n")}

      Dependabot:
      #{dependabot.reverse.map{|item| item.chomp(" (@dependabot[bot])")}.join("\n")}
    NOTES
    File.open(".release_notes", "w") {|f| f.write(release_notes)}
    run("open .release_notes", quiet: true)
  end

  def bundle_and_commit
    step "Bundle and commit".light_yellow

    check("branch is #{release_branch}", "git branch --show-current", release_branch)

    run("bundle install")
    run(%Q(git commit README_RELEASE.md Gemfile.lock .gitignore #{VERSION_FILE} README_RELEASE.md -m "Updating Gemfile.lock to #{version_number}"))
  end

  def build_gem
    step "Build the gem".light_yellow

    check("branch is #{release_branch}", "git branch --show-current", release_branch)

    run("gem build #{GEM_NAME}.gemspec")
    run("mv #{gem_filename} #{GEM_FOLDER}")
    run("open #{GEM_FOLDER}")
  end

  def confirm_release
    puts "Please check everything over and then type 'yes' to confirm this release".light_blue
    gets.chomp == "yes"
  end

  def complete_release!
    push_gem
    merge_and_push
  end

  ## utility methods

  def gem_filename
    "#{GEM_NAME}-#{version}.gem"
  end

  def push_gem
    step "Push gem to Gemfury".light_yellow

    api_token = run("cat ~/.fury/api-token")
    stop("No Gemfury api token found") if api_token.nil?

    filepath = "#{GEM_FOLDER}#{gem_filename}"
    run("fury push #{filepath} --api-token=#{api_token}")
  end

  def merge_and_push
    step "Merge release branch and push upstream".light_yellow

    check("branch is #{release_branch}", "git branch --show-current", release_branch)

    run %Q(git tag -a #{version_number} -m "Tagging #{version_number} release")
    run %Q(git push origin release/#{version_number}:release/#{version_number} --tags)
    run %Q(git checkout #{branch})
    run %Q(git merge release/#{version_number})
    run %Q(git push origin #{branch}:#{branch})
    if branch == "develop" && confirm_master_push
      run %Q(git checkout master)
      run %Q(git merge release/#{version_number})
      run %Q(git push origin master:master)
      run %Q(git checkout develop)
    end
  end

  def confirm_master_push
    puts "Please type 'master' to confirm".light_blue
    gets.chomp == "master"
  end

  def calculate_version(version_step)
    current_version = File.read(VERSION_FILE).scan(/\s*VERSION\s*=\s*"([0-9\.]+)"/).flatten.first
    points = current_version.split('.').map(&:to_i)
    case version_step.downcase
    when "major"
      points[0] += 1
    when "minor"
      points[1] += 1
    when "patch"
      points[2] += 1
    end
    points.join('.')
  end

  def release_branch
    "release/#{version_number}"
  end

  def compatible_version
    version.split(".")[0..1].join(".")
  end

  def commits
    @commits ||= begin
      last_tag = run(%Q(git describe --tags --abbrev=0 @^), quiet: true).chomp
      run(%Q(git log --pretty=format:"%s (@%aN)" #{last_tag}..@), quiet: true).split("\n")
    end
  end

  def decorate_commits(commits)
    client = Octokit::Client.new(:netrc => true)
    commits.map do |commit|
      if match = commit.match(/^(.+?)(\(#(\d+)\))(.+)$/)
        pull_no = match[3]
        title = client.pull_request(REPO, pull_no)&.title
        "- #{title} #{match[2]}#{match[4]}"
      end
    end.compact
  end

  def run(cmd, quiet: false)
    puts "> #{cmd.blue}"  unless quiet

    stdout, stderr, status = Open3.capture3(cmd)
    case status.exitstatus
    when 0
      stdout
    else
      puts stderr.red
      stop("command failed: #{cmd}")
    end
  end

  def verify_cmd(situation, cmd, output, quiet: false)
    stdout, stderr, status = Open3.capture3(cmd)
    verify(situation, stdout.match?(output), quiet: quiet)
  end

  def verify(situation, passed, quiet: false)
    if passed
      puts "Verfied: #{situation}".light_magenta unless quiet
    else
      stop "Failed to verify: #{situation}"
    end
  end

  def check(*args)
    verify_cmd(*args, quiet: true)
  end

  def stop(msg)
    puts msg.yellow
    exit
  end

  def step(msg)
    @step += 1
    puts "Step #{@step}: #{msg}".light_yellow
  end
end

Release.new(options).release
