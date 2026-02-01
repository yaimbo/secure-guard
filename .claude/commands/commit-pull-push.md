---
allowed-tools: Bash(git status:*), Bash(git add:*), Bash(git commit:*), Bash(git stash:*), Bash(git pull:*), Bash(git push:*)
description: Commit, pull, then push changes to remote
argument-hint: [commit message]
---

# Commit, Pull, and Push

Perform a git commit, pull, and push in sequence.

## Instructions

1. Run `git status` to see what will be committed
2. If there are changes to commit:
   - Stage all changes with `git add -A`
   - Commit with the provided message (or generate one if not provided)
3. Stash any unstaged changes if needed: `git stash` (to allow rebase)
4. Pull with rebase to sync latest changes: `git pull --rebase origin main`
5. Pop stash if used: `git stash pop` (ignore errors if stash was empty)
6. Push to remote if there are commits to push: `git push`

**Important:** Always perform the pull step even if there are no local changes to commit. This ensures you stay in sync with remote.

If any step fails, stop and report the error clearly.

The commit message is: $ARGUMENTS
