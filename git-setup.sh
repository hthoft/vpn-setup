#!/usr/bin/env bash
# Git Deploy Key Setup Script
# - Generates SSH deploy key for repository access
# - Configures SSH for repository cloning
# - Clones repository using deploy key

set -Eeuo pipefail
trap 'echo "Error on line $LINENO"; exit 1' ERR

# Check if running as root (not recommended for SSH keys)
if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  echo "WARNING: Running as root. SSH keys will be created in /root/.ssh/"
  echo "Consider running as a regular user for better security practices."
  read -r -p "Continue as root? (y/N): " CONTINUE_ROOT
  if [[ ! "$CONTINUE_ROOT" =~ ^[Yy]$ ]]; then
    echo "Exiting. Please run as a regular user."
    exit 1
  fi
fi

echo "=== Git Deploy Key Setup Script ==="
echo

# Get repository information
read -r -p "Enter the Git repository URL (e.g., git@github.com:user/repo.git): " REPO_URL
while [[ -z "$REPO_URL" ]]; do
  read -r -p "Please enter the repository URL: " REPO_URL
done

# Extract repository name from URL
REPO_NAME=$(basename "$REPO_URL" .git)
if [[ -z "$REPO_NAME" ]]; then
  echo "ERROR: Could not extract repository name from URL"
  exit 1
fi

# Get target directory
read -r -p "Enter target directory to clone into (default: ./$REPO_NAME): " TARGET_DIR
if [[ -z "$TARGET_DIR" ]]; then
  TARGET_DIR="./$REPO_NAME"
fi

# Check if target directory already exists
if [[ -d "$TARGET_DIR" ]]; then
  echo "WARNING: Directory '$TARGET_DIR' already exists"
  read -r -p "Remove existing directory and continue? (y/N): " REMOVE_DIR
  if [[ "$REMOVE_DIR" =~ ^[Yy]$ ]]; then
    rm -rf "$TARGET_DIR"
    echo "Removed existing directory"
  else
    echo "Exiting to avoid overwriting existing directory"
    exit 1
  fi
fi

echo
echo "Repository: $REPO_URL"
echo "Target Directory: $TARGET_DIR"
echo "Key Name: ${REPO_NAME}_deploy_key"
echo

# Create SSH directory if it doesn't exist
SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# Generate SSH key pair
KEY_NAME="${REPO_NAME}_deploy_key"
PRIVATE_KEY="$SSH_DIR/$KEY_NAME"
PUBLIC_KEY="$SSH_DIR/$KEY_NAME.pub"

if [[ -f "$PRIVATE_KEY" ]]; then
  echo "WARNING: Deploy key '$KEY_NAME' already exists"
  read -r -p "Overwrite existing key? (y/N): " OVERWRITE_KEY
  if [[ ! "$OVERWRITE_KEY" =~ ^[Yy]$ ]]; then
    echo "Using existing key..."
  else
    echo "Generating new SSH deploy key..."
    ssh-keygen -t ed25519 -f "$PRIVATE_KEY" -N "" -C "${KEY_NAME}@$(hostname)"
    chmod 600 "$PRIVATE_KEY"
    chmod 644 "$PUBLIC_KEY"
    echo "New key generated successfully"
  fi
else
  echo "Generating SSH deploy key..."
  ssh-keygen -t ed25519 -f "$PRIVATE_KEY" -N "" -C "${KEY_NAME}@$(hostname)"
  chmod 600 "$PRIVATE_KEY"
  chmod 644 "$PUBLIC_KEY"
  echo "Key generated successfully"
fi

# Display public key
echo
echo "=== Deploy Key Generated ==="
echo "Public key location: $PUBLIC_KEY"
echo "Private key location: $PRIVATE_KEY"
echo
echo "=== PUBLIC KEY TO ADD TO REPOSITORY ==="
echo "Copy the following public key and add it as a deploy key in your repository:"
echo
cat "$PUBLIC_KEY"
echo
echo "Instructions for adding deploy key:"
echo "GitHub:"
echo "  1. Go to your repository on GitHub"
echo "  2. Click Settings → Deploy Keys"
echo "  3. Click 'Add deploy key'"
echo "  4. Paste the public key above"
echo "  5. Give it a title (e.g., '${KEY_NAME}')"
echo "  6. Check 'Allow write access' if needed"
echo "  7. Click 'Add key'"
echo
echo "GitLab:"
echo "  1. Go to your repository on GitLab"
echo "  2. Click Settings → Repository → Deploy Keys"
echo "  3. Paste the public key above"
echo "  4. Give it a title (e.g., '${KEY_NAME}')"
echo "  5. Check 'Write access allowed' if needed"
echo "  6. Click 'Add key'"
echo

# Wait for user confirmation
read -r -p "Press Enter after you have added the deploy key to your repository..."

# Configure SSH for this repository
SSH_CONFIG="$SSH_DIR/config"
HOST_ALIAS="${REPO_NAME}-deploy"

# Extract hostname from repository URL
if [[ "$REPO_URL" =~ git@([^:]+): ]]; then
  GIT_HOST="${BASH_REMATCH[1]}"
else
  echo "ERROR: Could not extract hostname from repository URL"
  exit 1
fi

echo
echo "Configuring SSH..."

# Add SSH configuration
{
  echo
  echo "# Deploy key configuration for $REPO_NAME"
  echo "Host $HOST_ALIAS"
  echo "    HostName $GIT_HOST"
  echo "    User git"
  echo "    IdentityFile $PRIVATE_KEY"
  echo "    IdentitiesOnly yes"
  echo "    StrictHostKeyChecking no"
} >> "$SSH_CONFIG"

chmod 600 "$SSH_CONFIG"

echo "SSH configuration added to $SSH_CONFIG"

# Test SSH connection
echo "Testing SSH connection..."
if ssh -T "$HOST_ALIAS" 2>&1 | grep -q "successfully authenticated\|Welcome to"; then
  echo "SUCCESS: SSH connection test passed"
else
  echo "WARNING: SSH connection test may have failed, but this is often normal for deploy keys"
fi

# Modify repository URL to use our SSH alias
DEPLOY_REPO_URL=$(echo "$REPO_URL" | sed "s|git@$GIT_HOST:|git@$HOST_ALIAS:|")

echo
echo "Modified repository URL: $DEPLOY_REPO_URL"

# Clone the repository
echo "Cloning repository..."
if git clone "$DEPLOY_REPO_URL" "$TARGET_DIR"; then
  echo "SUCCESS: Repository cloned successfully to $TARGET_DIR"
else
  echo "ERROR: Failed to clone repository"
  echo "Please check:"
  echo "  1. The deploy key was added correctly to the repository"
  echo "  2. The repository URL is correct: $REPO_URL"
  echo "  3. You have the necessary permissions"
  exit 1
fi

# Configure git in the cloned repository (optional)
cd "$TARGET_DIR"

# Check if git user is configured globally
if ! git config --global user.name >/dev/null 2>&1 || ! git config --global user.email >/dev/null 2>&1; then
  echo
  echo "Git user not configured globally. Setting up local configuration..."
  read -r -p "Enter your name for git commits: " GIT_NAME
  read -r -p "Enter your email for git commits: " GIT_EMAIL
  
  if [[ -n "$GIT_NAME" && -n "$GIT_EMAIL" ]]; then
    git config user.name "$GIT_NAME"
    git config user.email "$GIT_EMAIL"
    echo "Git user configured locally for this repository"
  fi
fi

echo
echo "=== Setup Complete ==="
echo "Repository: $REPO_URL"
echo "Cloned to: $TARGET_DIR"
echo "SSH Key: $PRIVATE_KEY"
echo "SSH Config: Added $HOST_ALIAS to $SSH_CONFIG"
echo
echo "Useful commands:"
echo "  cd $TARGET_DIR                    # Enter repository directory"
echo "  git status                       # Check repository status"
echo "  git pull                         # Pull latest changes"
echo "  git push                         # Push changes (if write access enabled)"
echo "  ssh -T $HOST_ALIAS               # Test SSH connection"
echo
echo "To use this deploy key for future operations:"
echo "  - Use the repository URL: $DEPLOY_REPO_URL"
echo "  - Or work from within the cloned directory: $TARGET_DIR"
echo