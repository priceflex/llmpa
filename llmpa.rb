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
    @model = options[:model] || 'gpt-4.1-2025-04-14'
    @api_url = options[:api_url] || 'https://api.openai.com/v1/chat/completions'
    @project_dir = options[:project_dir] || Dir.pwd
    @file_extensions = options[:extensions] ? options[:extensions].split(',') : []
    @exclude_dirs = ['node_modules', '.git', 'vendor', 'tmp', 'log', 'coverage', 'build']
    @max_token_limit = options[:max_tokens] || 16000  # Default token limit
    
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
      # Confirm with the user if a Ruby code block was found
      if block[:language].downcase == "ruby"
        puts "\nWould you like me to write this Ruby code to a file? (yes/no)".cyan
        answer = gets.chomp.downcase
        
        if answer == "yes" || answer == "y"
          # Ask for a filename
          filename = prompt_for_input("Enter filename (or press Enter for auto-generated name): ")
          
          # Generate a filename if not provided
          if filename.empty?
            timestamp = Time.now.strftime("%Y%m%d%H%M%S")
            filename = "generated_code_#{timestamp}.rb"
          end
          
          # Add .rb extension if not present
          filename = "#{filename}.rb" unless filename.end_with?(".rb")
          
          # Write to file
          File.write(filename, block[:code])
          puts "Code written to #{filename}".green
          
          # Ask if they want to run the file
          puts "Would you like to run this file? (yes/no)".cyan
          if gets.chomp.downcase == "yes" || gets.chomp.downcase == "y"
            puts "Running #{filename}...".cyan
            puts "-" * 40
            system("ruby #{filename}")
            puts "-" * 40
            puts "Execution complete.".green
          end
          
          # Ask if they want to commit the file
          puts "Would you like to commit this file to git? (yes/no)".cyan
          if gets.chomp.downcase == "yes" || gets.chomp.downcase == "y"
            commit_message = prompt_for_input("Enter commit message (or press Enter for default): ")
            commit_message = "Add generated file #{filename}" if commit_message.empty?
            @git.add(filename)
            @git.commit(commit_message)
            puts "File committed with message: '#{commit_message}'".green
          end
        end
      end
    end
  end

  private
  
  def collect_files
    file_contents = []
    total_size = 0
    
    find_files.each do |file|
      next if File.size(file) > 1_000_000  # Skip files larger than 1MB
      
      begin
        content = File.read(file)
        file_size = content.bytesize
        
        # Skip adding more files if we're approaching the token limit
        # This is a rough estimate - 1 byte is approximately 0.75 tokens
        if (total_size + file_size) * 0.75 > @max_token_limit
          file_contents << "Note: Not all files were included due to token limits."
          break
        end
        
        relative_path = file.sub("#{@project_dir}/", '')
        file_contents << "File: #{relative_path}\n```\n#{content}\n```\n\n"
        total_size += file_size
      rescue => e
        file_contents << "Error reading file #{file}: #{e.message}"
      end
    end
    
    if file_contents.empty?
      return "No files found matching the criteria."
    end
    
    file_contents.join("\n")
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
    
    request.body = {
      "model" => @model,
      "messages" => messages,
      "temperature" => 0.7,
      "max_tokens" => 2000
    }.to_json
    
    begin
      response = http.request(request)
      
      if response.code == "200"
        result = JSON.parse(response.body)
        return result["choices"][0]["message"]["content"]
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
  
  opts.on("-h", "--help", "Show this help message") do
    puts opts
    exit
  end
end.parse!

# Run the application
LLMProjectAssistant.new(options).run