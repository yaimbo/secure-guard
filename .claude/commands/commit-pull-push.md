---
allowed-tools: Bash(git add:*), Bash(git commit:*), Bash(git pull:*), Bash(git push:*)
description: Commit, pull, then push changes to remote
argument-hint: [commit message]
---

# Commit, Pull, and Push

Perform a git commit, pull, and push in sequence.

## Instructions

1. Run `git status` to see what will be committed
2. Stage all changes with `git add -A`
3. Commit with the provided message (or generate one if not provided)
4. Pull with rebase to sync latest changes: `git pull --rebase`
5. Push to remote: `git push`

If any step fails, stop and report the error clearly.

The commit message is: $ARGUMENTS
