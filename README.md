# LLM Project Assistant (limpa)

A command-line tool that uses LLMs (like GPT-4 or Claude) to assist with code development by analyzing your project files and providing interactive help.

## Features

- **Codebase Analysis**: Automatically scans and ingests your project files for context
- **Interactive Development**: Chat with an LLM about your codebase to get assistance
- **Code Generation**: Generates ready-to-use code based on your requests
- **Code Execution**: Run generated Ruby scripts directly and get error fixing assistance
- **Git Integration**: Automatic backup via git commits before making changes
- **Custom File Filtering**: Filter by file extensions to focus on specific file types

## Installation

### Prerequisites

Make sure you have the following dependencies installed:

```bash
gem install optparse fileutils json colorize git
```

### Installation Steps

1. Clone this repository:
   ```bash
   git clone https://github.com/yourusername/llmpa.git
   cd llmpa
   ```

2. Make the script executable:
   ```bash
   chmod +x limpa.rb
   ```

3. Set up your API key:
   ```bash
   export LLM_API_KEY="your-api-key-here"
   ```

### Make Globally Accessible

To make this program accessible from anywhere on your system, add it to your PATH by creating a symbolic link:

```bash
sudo ln -s /path/to/llmpa/limpa.rb /usr/local/bin/limpa
```

Replace `/path/to/llmpa` with the actual path to your installation directory.

## Usage

### Basic Usage

```bash
limpa
```

This will analyze the current directory and start an interactive session.

### Command-line Options

```
Usage: limpa [options]
  -k, --api-key KEY                API key for the LLM service
  -m, --model MODEL                LLM model to use (default: gpt-4-turbo)
  -d, --directory DIR              Project directory (default: current directory)
  -e, --extensions EXT1,EXT2       Comma-separated list of file extensions to include
  -t, --max-tokens TOKENS          Maximum number of tokens for context
  -u, --api-url URL                API URL (default: OpenAI's endpoint)
      --anthropic                  Use Anthropic Claude API instead of OpenAI
  -h, --help                       Show this help message
```

### Examples

Use with OpenAI (default):
```bash
limpa -k your-openai-api-key -m gpt-4
```

Use with Anthropic Claude:
```bash
limpa --anthropic -k your-anthropic-api-key
```

Focus on specific file types:
```bash
limpa -e rb,js,py
```

### Interactive Commands

During the interactive session, you can use the following commands:

- `exit` - Exit the application
- `save` - Commit current changes to git
- `refresh` - Reload project files
- `help` - Show help message

## How It Works

1. The tool scans your project directory and collects file contents
2. It sends the files to an LLM (OpenAI or Anthropic) for analysis
3. You can ask questions about your codebase or request new features
4. The LLM responds with explanations and code
5. Generated code can be saved to files and committed to git
6. For Ruby files, the tool can execute and help debug them

## Tips for Best Results

- Keep your questions specific and clear
- Use `refresh` after making significant changes to your project
- For large projects, use the file extension filter to focus on relevant parts
- Commit your changes often with the `save` command

## License

[MIT License](LICENSE)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
