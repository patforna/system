#!/bin/bash

# Read JSON input from stdin
input=$(cat)

# Extract values from JSON
cwd=$(echo "$input" | jq -r '.workspace.current_dir')
model=$(echo "$input" | jq -r '.model.display_name')
style=$(echo "$input" | jq -r '.output_style.name')

# Get directory name
dir=$(basename "$cwd")

# Get git branch if in a git repo (skip optional locks for performance)
branch=""
if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  branch=$(git -C "$cwd" -c core.fileMode=false symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" -c core.fileMode=false rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    branch=" on \033[35m$branch\033[0m"
  fi
fi

# Build status line
status="\033[36m$dir\033[0m$branch"

# Add model info (shortened)
model_short=$(echo "$model" | sed 's/Claude //')
status="$status \033[32m$model_short\033[0m"

# Add output style if not default
if [ "$style" != "default" ] && [ "$style" != "null" ]; then
  status="$status \033[33m[$style]\033[0m"
fi

# Print the status line
printf "$status"
