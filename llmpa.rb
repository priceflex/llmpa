#!/usr/bin/env ruby
require 'optparse'
require 'fileutils'
require 'json'
require 'net/http'
require 'uri'
require 'colorize'
require 'git'

class LLMProjectAssistant
  def initialize(options)
    @api_key = options[:api_key] || ENV['LLM_API_KEY']
    @model = options[:model] || 'gpt-4-turbo'
    @api_url = options[:api_url] || 'https://api.openai.com/v1/chat/completions'
    @project_dir = options[:project_dir] || Dir.pwd
    @file_extensions = options[:extensions] ? options[:extensions].split(',') : []
    @exclude_dirs = ['node_modules', '.git', 'vendor', 'tmp', 'log', 'coverage', 'build']
    @max_token_limit = options[:max_tokens] || 16000  # Default token limit
    @use_anthropic = options[:use_anthropic] || false
    
    # Ensure we have an API key
    if @api_key.nil? || @api_key.empty?
      puts "Error: API key is required. Either provide with -k option or set LLM_API_KEY environment variable.".red
      exit 1
    end
    
    # Initialize git repo handler
    begin
      @git = Git.open(@project_dir)
    rescue ArgumentError => e
      puts "Error: Not a git repository. Please run this from a git repository.".red
      exit 1
    end
  end

  def run
    # First, commit any pending changes as a safety measure
    commit_changes("Auto-commit before LLM interaction")
    
    # Collect project files
    puts "Collecting project files...".cyan
    files_content = collect_files
    
    # Create the initial system message
    system_message = {
      "role" => "system",
      "content" => "You are a programming assistant that helps with code development. You are given the content of various files in a project. Your task is to help the user understand the codebase and assist with implementing new features. Always provide concise and relevant code snippets. Before suggesting modifications, explain your approach briefly."
    }
    
    # Create the file context message
    file_context = {
      "role" => "user",
      "content" => "Here are the files in my project: \n\n#{files_content}\n\nPlease help me understand and enhance this codebase."
    }
    
    messages = [system_message, file_context]
    
    # Start interactive session
    puts "\nLLM Project Assistant ready! Type your questions about the project or features you want to implement.".green
    puts "Type 'exit' to quit, 'save' to commit changes, or 'refresh' to reload project files.\n".green
    
    loop do
      print "> ".yellow
      input = gets.chomp
      
      case input.downcase
      when 'exit'
        puts "Exiting...".cyan
        break
      when 'save'
        commit_message = prompt_for_input("Enter commit message: ")
        commit_changes(commit_message)
        next
      when 'refresh'
        puts "Refreshing project files...".cyan
        files_content = collect_files
        # Update the file context message
        file_context["content"] = "Here are the updated files in my project: \n\n#{files_content}\n\nPlease continue helping me with this codebase."
        messages = [system_message, file_context, *messages.drop(2).last(10)]  # Keep the last 10 conversation messages
        puts "Project files refreshed!".green
        next
      end
      
      # Add user message to the conversation
      messages << {"role" => "user", "content" => input}
      
      # Get response from LLM
      puts "Thinking...".cyan
      response = call_llm_api(messages)
      
      if response
        # Add assistant response to the conversation
        messages << {"role" => "assistant", "content" => response}
        
        # Print the response
        puts "\nAssistant:".green
        puts response
        puts "\n"
        
        # Check for code blocks in the response
        code_blocks = extract_code_blocks(response)
        if code_blocks.any?
          handle_code_blocks(code_blocks)
        end
      else
        puts "Failed to get a response from the LLM.".red
      end
      
      # Ensure we don't exceed token limits by trimming conversation history
      # This is a simple approach - a more sophisticated one would count tokens
      if messages.size > 12  # Keep system + file context + last 10 exchanges
        messages = [system_message, file_context, *messages.drop(4)]
      end
    end
  end
  
  # Add a new method to run a Ruby file with exception handling
  def run_ruby_file_with_error_handling(filename)
    puts "Running #{filename}...".cyan
    puts "-" * 40
    
    # Create a temporary file to capture error output
    error_file = "#{filename}_error.log"
    
    begin
      # Run the Ruby file and capture both stdout and stderr
      system("ruby #{filename} 2>#{error_file}")
      exit_status = $?.exitstatus
      
      if exit_status == 0
        puts "-" * 40
        puts "Execution complete.".green
        # Remove the error file if no errors
        File.delete(error_file) if File.exist?(error_file)
        return true
      else
        puts "-" * 40
        puts "Execution failed with exit status #{exit_status}.".red
        
        # Read the error output
        if File.exist?(error_file) && !File.zero?(error_file)
          error_message = File.read(error_file)
          puts "Error details:".red
          puts error_message
          
          # Ask if the user wants to send this to the LLM for fixing
          puts "\nWould you like to send this error to the LLM for a fix? (yes/no)".cyan
          if gets.chomp.downcase == "yes" || gets.chomp.downcase == "y"
            # Allow the user to add comments to help with the fix
            puts "Add any comments to help with fixing this error (optional):".cyan
            user_comments = gets.chomp
            
            # Get the code content
            code_content = File.read(filename)
            
            # Create the error fix prompt
            error_fix_prompt = "I have a Ruby script that's throwing the following error:\n\n"
            error_fix_prompt += "```\n#{error_message}\n```\n\n"
            error_fix_prompt += "Here's the code:\n\n"
            error_fix_prompt += "```ruby\n#{code_content}\n```\n\n"
            error_fix_prompt += "#{user_comments}\n\n" unless user_comments.empty?
            error_fix_prompt += "Please explain what's causing this error and provide a fixed version of the code."
            
            # Create a one-time message to the LLM
            fix_messages = [
              {
                "role" => "system", 
                "content" => "You are a programming assistant that specializes in fixing Ruby code errors. Provide clear explanations of errors and suggest fixes."
              },
              {
                "role" => "user",
                "content" => error_fix_prompt
              }
            ]
            
            # Call the LLM API
            puts "Asking the LLM for a fix...".cyan
            response = call_llm_api(fix_messages)
            
            if response
              puts "\nFix Suggestion:".green
              puts response
              puts "\n"
              
              # Extract code blocks from the response
              code_blocks = extract_code_blocks(response)
              if code_blocks.any?
                puts "Would you like to apply one of the suggested fixes? (yes/no)".cyan
                if gets.chomp.downcase == "yes" || gets.chomp.downcase == "y"
                  # If there are multiple code blocks, let the user choose
                  selected_block = nil
                  if code_blocks.size > 1
                    puts "Multiple code blocks found. Which one would you like to use?".cyan
                    code_blocks.each_with_index do |block, index|
                      puts "\nOption #{index + 1}:".cyan
                      puts "```ruby"
                      puts block[:code]
                      puts "```"
                    end
                    
                    print "Enter option number (1-#{code_blocks.size}): ".yellow
                    option = gets.chomp.to_i
                    if option >= 1 && option <= code_blocks.size
                      selected_block = code_blocks[option - 1]
                    else
                      puts "Invalid option. Using the first code block.".yellow
                      selected_block = code_blocks[0]
                    end
                  else
                    selected_block = code_blocks[0]
                  end
                  
                  # Backup the original file
                  backup_filename = "#{filename}.backup.#{Time.now.strftime('%Y%m%d%H%M%S')}"
                  FileUtils.cp(filename, backup_filename)
                  puts "Original file backed up to #{backup_filename}".green
                  
                  # Write the fixed code to the file
                  File.write(filename, selected_block[:code])
                  puts "Fixed code written to #{filename}".green
                  
                  # Ask if they want to run the fixed file
                  puts "Would you like to run the fixed file? (yes/no)".cyan
                  if gets.chomp.downcase == "yes" || gets.chomp.downcase == "y"
                    run_ruby_file_with_error_handling(filename)
                  end
                  
                  # Ask if they want to commit the fixed file
                  puts "Would you like to commit the fixed file to git? (yes/no)".cyan
                  if gets.chomp.downcase == "yes" || gets.chomp.downcase == "y"
                    commit_message = prompt_for_input("Enter commit message (or press Enter for default): ")
                    commit_message = "Fix error in #{filename}" if commit_message.empty?
                    
                    begin
                      @git.add(filename)
                      @git.commit(commit_message)
                      puts "Fixed file committed with message: '#{commit_message}'".green
                    rescue => e
                      puts "Error committing file: #{e.message}".red
                    end
                  end
                end
              end
            else
              puts "Failed to get a fix suggestion from the LLM.".red
            end
          end
        end
        
        # Clean up
        File.delete(error_file) if File.exist?(error_file)
        return false
      end
    rescue => e
      puts "Error running file: #{e.message}".red
      return false
    ensure
      # Make sure we clean up the error file
      File.delete(error_file) if File.exist?(error_file)
    end
  end
  
  def extract_code_blocks(text)
    # Extract code blocks from markdown-formatted text
    # Matches both triple-backtick code blocks with optional language specifier
    code_blocks = []
    
    # Pattern for ```language\ncode\n``` style blocks
    text.scan(/```(?:(\w+)\n)?(.*?)```/m) do |language, code|
      language ||= "ruby"  # Default to ruby if language not specified
      code_blocks << { language: language, code: code.strip }
    end
    
    code_blocks
  end
  
  def handle_code_blocks(code_blocks)
    code_blocks.each do |block|
      # Handle code differently based on language
      language = block[:language].downcase
      extension = get_extension_for_language(language)
      
      if extension
        puts "\nI found a #{language.capitalize} code snippet.".cyan
        puts "Would you like me to write this code to a file? (yes/no)".cyan
        answer = gets.chomp.downcase
        
        if answer == "yes" || answer == "y"
          # Ask for a filename
          filename = prompt_for_input("Enter filename (or press Enter for auto-generated name): ")
          
          # Generate a filename if not provided
          if filename.empty?
            timestamp = Time.now.strftime("%Y%m%d%H%M%S")
            filename = "generated_#{language}_#{timestamp}"
          end
          
          # Add appropriate extension if not present
          unless filename.end_with?(extension)
            filename = "#{filename}#{extension}"
          end
          
          # Check if file exists and confirm overwrite
          if File.exist?(filename)
            puts "File #{filename} already exists. Overwrite? (yes/no)".yellow
            if gets.chomp.downcase != "yes" && gets.chomp.downcase != "y"
              puts "File not saved.".yellow
              next
            end
          end
          
          # Write to file
          File.write(filename, block[:code])
          puts "Code written to #{filename}".green
          
          # For Ruby files, offer to run them
          if language == "ruby"
            puts "Would you like to run this file? (yes/no)".cyan
            run_answer = gets.chomp.downcase
            if run_answer == "yes" || run_answer == "y"
              run_ruby_file_with_error_handling(filename)
            end
          end
          
          # Ask if they want to commit the file
          puts "Would you like to commit this file to git? (yes/no)".cyan
          commit_answer = gets.chomp.downcase
          if commit_answer == "yes" || commit_answer == "y"
            commit_message = prompt_for_input("Enter commit message (or press Enter for default): ")
            commit_message = "Add #{language} file: #{filename}" if commit_message.empty?
            
            begin
              @git.add(filename)
              @git.commit(commit_message)
              puts "File committed with message: '#{commit_message}'".green
            rescue => e
              puts "Error committing file: #{e.message}".red
            end
          end
        end
      end
    end
  end
  
  def get_extension_for_language(language)
    # Common language to file extension mapping
    extensions = {
      "ruby" => ".rb",
      "python" => ".py",
      "javascript" => ".js",
      "typescript" => ".ts",
      "java" => ".java",
      "c" => ".c",
      "cpp" => ".cpp",
      "csharp" => ".cs",
      "php" => ".php",
      "go" => ".go",
      "rust" => ".rs",
      "swift" => ".swift",
      "kotlin" => ".kt",
      "html" => ".html",
      "css" => ".css",
      "sql" => ".sql",
      "shell" => ".sh",
      "bash" => ".sh",
      "powershell" => ".ps1",
      "yaml" => ".yml",
      "json" => ".json",
      "xml" => ".xml",
      "markdown" => ".md"
    }
    
    extensions[language]
  end

  private
  
  def collect_files
    file_contents = []
    total_size = 0
    total_files = 0
    included_files = 0
    excluded_files = 0
    
    puts "Scanning project directory...".cyan
    all_files = find_files
    total_files = all_files.size
    
    puts "Found #{total_files} files to analyze...".cyan
    
    all_files.each do |file|
      next if File.size(file) > 1_000_000  # Skip files larger than 1MB
      
      begin
        content = File.read(file)
        file_size = content.bytesize
        
        # Skip adding more files if we're approaching the token limit
        # This is a rough estimate - 1 byte is approximately 0.75 tokens
        if (total_size + file_size) * 0.75 > @max_token_limit
          excluded_files += 1
          next
        end
        
        relative_path = file.sub("#{@project_dir}/", '')
        file_contents << "File: #{relative_path}\n```#{get_language_from_file(file)}\n#{content}\n```\n\n"
        total_size += file_size
        included_files += 1
      rescue => e
        puts "Error reading file #{file}: #{e.message}".yellow
        excluded_files += 1
      end
    end
    
    puts "Included #{included_files} files (#{format_size(total_size)})".cyan
    puts "Excluded #{excluded_files} files due to size or token limits".cyan if excluded_files > 0
    
    if file_contents.empty?
      return "No files found matching the criteria."
    end
    
    file_contents.join("\n")
  end
  
  def format_size(size_in_bytes)
    if size_in_bytes < 1024
      "#{size_in_bytes} B"
    elsif size_in_bytes < 1024 * 1024
      "#{(size_in_bytes.to_f / 1024).round(2)} KB"
    else
      "#{(size_in_bytes.to_f / (1024 * 1024)).round(2)} MB"
    end
  end
  
  def get_language_from_file(file)
    # Map file extensions to language names for better code block formatting
    extension = File.extname(file).downcase
    case extension
    when ".rb"
      "ruby"
    when ".py"
      "python"
    when ".js"
      "javascript"
    when ".ts"
      "typescript"
    when ".java"
      "java"
    when ".html"
      "html"
    when ".css"
      "css"
    when ".php"
      "php"
    when ".go"
      "go"
    when ".rs"
      "rust"
    when ".c", ".cpp", ".h"
      "cpp"
    when ".cs"
      "csharp"
    when ".sh"
      "bash"
    when ".sql"
      "sql"
    when ".json"
      "json"
    when ".yml", ".yaml"
      "yaml"
    when ".md"
      "markdown"
    else
      "" # Empty means no specific language highlighting
    end
  end
  
  def find_files
    all_files = []
    
    Dir.glob("#{@project_dir}/**/*").each do |file|
      next if File.directory?(file)
      next if @exclude_dirs.any? { |dir| file.include?("/#{dir}/") }
      
      # If specific extensions were provided, filter by them
      if @file_extensions.any?
        extension = File.extname(file).sub(/^\./, '')
        next unless @file_extensions.include?(extension)
      end
      
      all_files << file
    end
    
    all_files
  end
  
  def call_llm_api(messages)
    uri = URI.parse(@api_url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    
    request = Net::HTTP::Post.new(uri.request_uri)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{@api_key}"
    
    if @use_anthropic
      # Format messages for Anthropic Claude API
      formatted_messages = []
      messages.each do |msg|
        role = msg["role"] == "assistant" ? "assistant" : "user"
        formatted_messages << {"role" => role, "content" => msg["content"]}
      end
      
      request.body = {
        "model" => @model,
        "messages" => formatted_messages,
        "temperature" => 0.7,
        "max_tokens" => 2000
      }.to_json
      
      # Add Anthropic-specific headers
      request["x-api-key"] = @api_key
      request["anthropic-version"] = "2023-06-01"
    else
      # Format for OpenAI API
      request.body = {
        "model" => @model,
        "messages" => messages,
        "temperature" => 0.7,
        "max_tokens" => 2000
      }.to_json
    end
    
    begin
      response = http.request(request)
      
      if response.code == "200"
        result = JSON.parse(response.body)
        if @use_anthropic
          return result["content"][0]["text"]
        else
          return result["choices"][0]["message"]["content"]
        end
      else
        puts "API Error: #{response.code} - #{response.body}".red
        return nil
      end
    rescue => e
      puts "Error calling API: #{e.message}".red
      return nil
    end
  end
  
  def commit_changes(message)
    begin
      # Check if there are changes to commit
      status = @git.status
      if status.changed.empty? && status.added.empty? && status.deleted.empty?
        puts "No changes to commit.".yellow
        return
      end
      
      # Add all changes
      @git.add(all: true)
      
      # Commit changes
      @git.commit(message)
      puts "Changes committed with message: '#{message}'".green
    rescue => e
      puts "Error committing changes: #{e.message}".red
    end
  end
  
  def prompt_for_input(message)
    print message.yellow
    gets.chomp
  end
end

# Add some helper methods
def show_welcome_message
  puts "=" * 80
  puts "LLM Project Assistant".center(80)
  puts "=" * 80
  puts "This tool ingests your project files and uses an LLM to help you develop new features."
  puts "It automatically commits changes to git before making modifications as a safety measure."
  puts
  puts "Commands:".cyan
  puts "  exit     - Exit the application"
  puts "  save     - Commit current changes to git"
  puts "  refresh  - Reload project files"
  puts "  help     - Show this help message"
  puts "=" * 80
end

# Parse command line options
options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: llm_project_assistant.rb [options]"

  opts.on("-k", "--api-key KEY", "API key for the LLM service") do |key|
    options[:api_key] = key
  end
  
  opts.on("-m", "--model MODEL", "LLM model to use (default: gpt-4-turbo)") do |model|
    options[:model] = model
  end
  
  opts.on("-d", "--directory DIR", "Project directory (default: current directory)") do |dir|
    options[:project_dir] = dir
  end
  
  opts.on("-e", "--extensions EXT1,EXT2", "Comma-separated list of file extensions to include") do |exts|
    options[:extensions] = exts
  end
  
  opts.on("-t", "--max-tokens TOKENS", Integer, "Maximum number of tokens for context") do |tokens|
    options[:max_tokens] = tokens
  end
  
  opts.on("-u", "--api-url URL", "API URL (default: OpenAI's endpoint)") do |url|
    options[:api_url] = url
  end
  
  opts.on("--anthropic", "Use Anthropic Claude API instead of OpenAI") do
    options[:api_url] = "https://api.anthropic.com/v1/messages"
    options[:model] = "claude-3-opus-20240229"
    options[:use_anthropic] = true
  end
  
  opts.on("-h", "--help", "Show this help message") do
    puts opts
    exit
  end
end.parse!

# Show welcome message
show_welcome_message

# Run the application
LLMProjectAssistant.new(options).run