#!/bin/bash

# Read JSON input from stdin
input=$(cat)

# Extract values from JSON
cwd=$(echo "$input" | jq -r '.workspace.current_dir')
model=$(echo "$input" | jq -r '.model.display_name')
style=$(echo "$input" | jq -r '.output_style.name')

# Get directory path (collapse $HOME to ~, shorten Google Drive)
dir=$(echo "$cwd" | sed "s|^$HOME|~|" | sed 's|~/Library/CloudStorage/GoogleDrive-[^/]*/My Drive|~/Drive|')

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

# Context window usage bar
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | awk '{printf "%d", $1}')
if [ "$used_pct" -gt 0 ] 2>/dev/null; then
  bar_width=10
  filled=$(( used_pct * bar_width / 100 ))
  empty=$(( bar_width - filled ))
  # Color: green < 60%, yellow 60-80%, red > 80%
  if [ "$used_pct" -ge 80 ]; then
    color="\033[31m"
  elif [ "$used_pct" -ge 60 ]; then
    color="\033[33m"
  else
    color="\033[32m"
  fi
  filled_str=""; [ "$filled" -gt 0 ] && filled_str=$(printf '▓%.0s' $(seq 1 $filled))
  empty_str=""; [ "$empty" -gt 0 ] && empty_str=$(printf '░%.0s' $(seq 1 $empty))
  bar="${color}${filled_str}${empty_str}\033[0m"
  status="$status ${bar} ${color}${used_pct}%\033[0m"
fi

# Print the status line
printf '%b' "$status"
