#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Configuration
MAINTAINER_NAME=""
MAINTAINER_EMAIL=""
LAUNCHPAD_USERNAME=""
GPG_KEY=""

# Configuration file path
CONFIG_DIR="$HOME/.config/ppa_builder"
CONFIG_FILE="$CONFIG_DIR/config"

# Function to load saved configuration
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        echo -e "${BLUE}Loading saved configuration...${NC}"
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

# Function to save configuration
save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << EOF
MAINTAINER_NAME="$MAINTAINER_NAME"
MAINTAINER_EMAIL="$MAINTAINER_EMAIL"
LAUNCHPAD_USERNAME="$LAUNCHPAD_USERNAME"
GPG_KEY="$GPG_KEY"
EOF
    chmod 600 "$CONFIG_FILE"
    echo -e "${GREEN}Configuration saved${NC}"
}

# Function to check and install required packages
check_dependencies() {
    local REQUIRED_PACKAGES="build-essential debhelper devscripts dput gnupg ubuntu-dev-tools"
    local MISSING_PACKAGES=""
    
    echo -e "${BLUE}Checking required packages...${NC}"
    for package in $REQUIRED_PACKAGES; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            MISSING_PACKAGES="$MISSING_PACKAGES $package"
        fi
    done
    
    if [ ! -z "$MISSING_PACKAGES" ]; then
        echo -e "${BLUE}Installing missing packages:${NC}$MISSING_PACKAGES"
        if [ "$EUID" -ne 0 ]; then
            echo -e "${BLUE}Requesting sudo privileges to install packages...${NC}"
            if ! sudo apt-get update; then
                echo -e "${RED}Failed to update package lists${NC}"
                exit 1
            fi
            if ! sudo apt-get install -y $MISSING_PACKAGES; then
                echo -e "${RED}Failed to install required packages${NC}"
                exit 1
            fi
        else
            if ! apt-get update; then
                echo -e "${RED}Failed to update package lists${NC}"
                exit 1
            fi
            if ! apt-get install -y $MISSING_PACKAGES; then
                echo -e "${RED}Failed to install required packages${NC}"
                exit 1
            fi
        fi
        echo -e "${GREEN}All required packages installed successfully${NC}"
    else
        echo -e "${GREEN}All required packages are already installed${NC}"
    fi
}

# Function to validate source directory
validate_source() {
    local SOURCE_DIR=$1
    echo -e "${BLUE}Validating source directory: $SOURCE_DIR${NC}"
    
    # Check if directory exists
    if [ ! -d "$SOURCE_DIR" ]; then
        echo -e "${RED}Error: Source directory does not exist: $SOURCE_DIR${NC}"
        exit 1
    fi
    
    # Check for build files with more detailed output
    echo -e "${BLUE}Checking for build system files...${NC}"
    local has_makefile=0
    local has_cmake=0
    
    if [ -f "$SOURCE_DIR/Makefile" ]; then
        echo -e "${GREEN}Found Makefile${NC}"
        has_makefile=1
    fi
    
    if [ -f "$SOURCE_DIR/CMakeLists.txt" ]; then
        echo -e "${GREEN}Found CMakeLists.txt${NC}"
        has_cmake=1
    fi
    
    if [ $has_makefile -eq 0 ] && [ $has_cmake -eq 0 ]; then
        echo -e "${BLUE}Warning: No Makefile or CMakeLists.txt found. You'll need to specify build instructions.${NC}"
    fi
    
    # List directory contents for verification
    echo -e "${BLUE}Source directory contents:${NC}"
    ls -la "$SOURCE_DIR"
}

# Function to validate email
validate_email() {
    local email="$1"
    if [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        return 0
    fi
    return 1
}

# Function to get user information
get_user_info() {
    local SKIP_PROMPTS=false
    
    # Check for existing config
    if load_config; then
        echo -e "Current configuration:"
        echo -e "  Name: $MAINTAINER_NAME"
        echo -e "  Email: $MAINTAINER_EMAIL"
        echo -e "  Launchpad Username: $LAUNCHPAD_USERNAME"
        echo -e "  GPG Key: ${GPG_KEY:-Not set}"
        
        read -p "Would you like to use this configuration? (Y/n): " USE_EXISTING
        if [[ $USE_EXISTING =~ ^[Yy]?$ ]]; then
            SKIP_PROMPTS=true
        fi
    fi
    
    if [ "$SKIP_PROMPTS" = false ]; then
        echo -e "${BLUE}Please enter your information:${NC}"
        
        # Get and validate name
        while true; do
            read -p "Full Name: " MAINTAINER_NAME
            if [[ -n "$MAINTAINER_NAME" ]]; then
                break
            fi
            echo -e "${RED}Error: Name cannot be empty${NC}"
        done
        
        # Get and validate email
        while true; do
            read -p "Email Address: " MAINTAINER_EMAIL
            if validate_email "$MAINTAINER_EMAIL"; then
                break
            fi
            echo -e "${RED}Error: Invalid email format. Please use format: user@domain.com${NC}"
        done
        
        # Get and validate Launchpad username
        while true; do
            read -p "Launchpad Username: " LAUNCHPAD_USERNAME
            if [[ -n "$LAUNCHPAD_USERNAME" ]]; then
                break
            fi
            echo -e "${RED}Error: Launchpad username cannot be empty${NC}"
        done
        
        # Save the new configuration
        save_config
    fi
}

# Function to get package information
get_package_info() {
    echo -e "${BLUE}Please enter package information:${NC}"
    read -p "Package name (lowercase, no spaces): " PACKAGE_NAME
    read -p "Package version (e.g., 1.0.0): " PACKAGE_VERSION
    read -p "Package description: " PACKAGE_DESCRIPTION
    
    # Validate package name
    if [[ ! $PACKAGE_NAME =~ ^[a-z][a-z0-9-]*$ ]]; then
        echo -e "${RED}Error: Invalid package name. Use only lowercase letters, numbers, and hyphens.${NC}"
        exit 1
    fi
    
    # Validate version
    if [[ ! $PACKAGE_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo -e "${RED}Error: Invalid version format. Use semantic versioning (e.g., 1.0.0)${NC}"
        exit 1
    fi

    # Set default dependencies
    PACKAGE_DEPS="build-essential debhelper-compat (= 13) cmake"
}

# Function to analyze dependencies
analyze_dependencies() {
    local SOURCE_DIR=$1
    local BUILD_DIR=$2
    local DETECTED_DEPS=""
    
    echo -e "${BLUE}Analyzing project dependencies...${NC}"
    
    # Check CMakeLists.txt first
    if [ -f "$SOURCE_DIR/CMakeLists.txt" ]; then
        echo -e "${BLUE}Found CMakeLists.txt, checking for dependencies...${NC}"
        # Basic CMake dependencies
        DETECTED_DEPS="cmake build-essential"
        
        # Check for specific packages
        if grep -q "find_package.*GTK" "$SOURCE_DIR/CMakeLists.txt" 2>/dev/null; then
            DETECTED_DEPS="$DETECTED_DEPS libgtk-3-dev"
        fi
        if grep -q "find_package.*Qt" "$SOURCE_DIR/CMakeLists.txt" 2>/dev/null; then
            DETECTED_DEPS="$DETECTED_DEPS qtbase5-dev"
        fi
        if grep -q "find_package.*CURL" "$SOURCE_DIR/CMakeLists.txt" 2>/dev/null; then
            DETECTED_DEPS="$DETECTED_DEPS libcurl4-openssl-dev"
        fi
        if grep -q "find_package.*SQLite" "$SOURCE_DIR/CMakeLists.txt" 2>/dev/null; then
            DETECTED_DEPS="$DETECTED_DEPS libsqlite3-dev"
        fi
    else
        echo -e "${YELLOW}No CMakeLists.txt found, using basic dependencies${NC}"
        DETECTED_DEPS="build-essential"
    fi
    
    # Remove duplicates and format
    DETECTED_DEPS=$(echo "$DETECTED_DEPS" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed -e 's/^ *//' -e 's/ *$//')
    
    if [ -n "$DETECTED_DEPS" ]; then
        echo -e "${BLUE}Detected dependencies: $DETECTED_DEPS${NC}"
    else
        echo -e "${BLUE}No additional dependencies detected${NC}"
    fi
    
    # Save dependencies
    echo "$DETECTED_DEPS" > "$BUILD_DIR/debian/deps"
}

# Function to create debian directory structure
create_debian_dir() {
    local SOURCE_DIR=$1
    local PACKAGE_NAME=$2
    local VERSION=$3
    local DESCRIPTION=$4
    
    echo -e "${BLUE}Creating debian directory structure...${NC}"
    
    # Create debian directory
    mkdir -p "$SOURCE_DIR/debian"
    
    # Create control file with minimal dependencies
    cat > "$SOURCE_DIR/debian/control" << EOF
Source: $PACKAGE_NAME
Section: utils
Priority: optional
Maintainer: $MAINTAINER_NAME <$MAINTAINER_EMAIL>
Build-Depends: debhelper-compat (= 13)
Standards-Version: 4.5.1
Homepage: https://launchpad.net/~$LAUNCHPAD_USERNAME/+archive/ubuntu/ppa

Package: $PACKAGE_NAME
Architecture: any
Depends: \${shlibs:Depends}, \${misc:Depends}
Description: $DESCRIPTION
 A simple test project for demonstrating package creation.
EOF
    
    # Create rules file
    cat > "$SOURCE_DIR/debian/rules" << 'EOF'
#!/usr/bin/make -f
%:
	dh $@

override_dh_auto_configure:
	dh_auto_configure -- -DCMAKE_BUILD_TYPE=Release
EOF
    chmod +x "$SOURCE_DIR/debian/rules"
    
    # Create compat file
    echo "13" > "$SOURCE_DIR/debian/compat"
    
    # Create changelog file
    TIMESTAMP=$(date -R)
    cat > "$SOURCE_DIR/debian/changelog" << EOF
$PACKAGE_NAME ($VERSION-1) unstable; urgency=medium

  * Initial release

 -- $MAINTAINER_NAME <$MAINTAINER_EMAIL>  $TIMESTAMP
EOF
    
    # Create source format
    mkdir -p "$SOURCE_DIR/debian/source"
    echo "3.0 (native)" > "$SOURCE_DIR/debian/source/format"
    
    echo -e "${GREEN}Debian directory structure created successfully${NC}"
}

# Function to create debian package structure
create_debian_structure() {
    local SOURCE_DIR=$1
    local BUILD_DIR="/tmp/ppa_build/${PACKAGE_NAME}-${PACKAGE_VERSION}"
    
    echo -e "${BLUE}Creating package structure...${NC}"
    
    # Create build directory
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    
    # Copy source files
    cp -r "$SOURCE_DIR"/* "$BUILD_DIR/"
    
    # Create debian directory
    create_debian_dir "$BUILD_DIR" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$PACKAGE_DESCRIPTION"
    
    # Analyze dependencies
    analyze_dependencies "$SOURCE_DIR" "$BUILD_DIR"
    local DETECTED_DEPS=$(cat "$BUILD_DIR/debian/deps")
    
    # Update control file with dependencies
    if [ -n "$DETECTED_DEPS" ]; then
        sed -i "s/Build-Depends: debhelper-compat (= 13)/Build-Depends: debhelper-compat (= 13), $DETECTED_DEPS/" "$BUILD_DIR/debian/control"
    fi
    
    # Create source tarball
    cd "/tmp/ppa_build"
    tar czf "${PACKAGE_NAME}_${PACKAGE_VERSION}.orig.tar.gz" "${PACKAGE_NAME}-${PACKAGE_VERSION}"
    
    echo -e "${GREEN}Package structure created successfully${NC}"
}

# Function to build source package
build_source_package() {
    local BUILD_DIR="/tmp/ppa_build/${PACKAGE_NAME}-${PACKAGE_VERSION}"
    cd "$BUILD_DIR"
    
    echo -e "${BLUE}Building source package...${NC}"
    yes | debuild -S -sa
    
    if [ $? -ne 0 ]; then
        echo -e "${RED}Error: Package build failed${NC}"
        exit 1
    fi
}

# Function to upload to PPA
upload_to_ppa() {
    # Configure dput
    cat > ~/.dput.cf << EOF
[ppa]
fqdn = ppa.launchpad.net
method = ftp
incoming = ~$LAUNCHPAD_USERNAME/ubuntu/$PACKAGE_NAME/
login = anonymous
allow_unsigned_uploads = 0
EOF
    
    echo -e "${BLUE}Uploading package to PPA...${NC}"
    cd "/tmp/ppa_build"
    dput ppa "${PACKAGE_NAME}_${PACKAGE_VERSION}-1_source.changes"
}

# Function to add PPA to system sources
add_ppa_to_system() {
    echo -e "${BLUE}Adding PPA to system sources...${NC}"
    
    # Check if add-apt-repository is available
    if ! command -v add-apt-repository &> /dev/null; then
        echo -e "${BLUE}Installing software-properties-common...${NC}"
        if [ "$EUID" -ne 0 ]; then
            sudo apt-get update && sudo apt-get install -y software-properties-common
        else
            apt-get update && apt-get install -y software-properties-common
        fi
    fi
    
    # Add the PPA
    local PPA_PATH="ppa:$LAUNCHPAD_USERNAME/$PACKAGE_NAME"
    echo -e "${BLUE}Adding PPA:${NC} $PPA_PATH"
    
    if [ "$EUID" -ne 0 ]; then
        if ! sudo add-apt-repository -y "$PPA_PATH"; then
            echo -e "${RED}Failed to add PPA${NC}"
            return 1
        fi
        if ! sudo apt-get update; then
            echo -e "${RED}Failed to update package lists${NC}"
            return 1
        fi
    else
        if ! add-apt-repository -y "$PPA_PATH"; then
            echo -e "${RED}Failed to add PPA${NC}"
            return 1
        fi
        if ! apt-get update; then
            echo -e "${RED}Failed to update package lists${NC}"
            return 1
        fi
    fi
    
    echo -e "${GREEN}PPA added successfully!${NC}"
    echo -e "${BLUE}You can now install your package with:${NC}"
    echo -e "sudo apt-get install $PACKAGE_NAME"
    return 0
}

# Function to setup GPG key
setup_gpg() {
    echo -e "${BLUE}GPG Key Setup${NC}"
    
    # If we already have a GPG key from config, ask if we want to use it
    if [ -n "$GPG_KEY" ]; then
        echo -e "Current GPG key: $GPG_KEY"
        read -p "Would you like to use this GPG key? (Y/n): " USE_EXISTING_KEY
        if [[ $USE_EXISTING_KEY =~ ^[Yy]?$ ]]; then
            # Verify the key exists
            if gpg --list-secret-keys "$GPG_KEY" &>/dev/null; then
                echo -e "${GREEN}Using existing GPG key${NC}"
                return 0
            else
                echo -e "${RED}Configured GPG key not found in keyring${NC}"
            fi
        fi
    fi
    
    # Check for existing GPG keys
    if gpg --list-secret-keys | grep -q "sec"; then
        echo -e "${BLUE}Existing GPG keys found:${NC}"
        gpg --list-secret-keys
        read -p "Would you like to use an existing key? (y/n): " USE_EXISTING
        if [[ $USE_EXISTING =~ ^[Yy]$ ]]; then
            while true; do
                read -p "Enter the GPG key ID to use: " GPG_KEY
                if gpg --list-secret-keys "$GPG_KEY" &>/dev/null; then
                    break
                fi
                echo -e "${RED}Error: Key not found. Please enter a valid key ID${NC}"
            done
            save_config
            return 0
        fi
    fi
    
    # Generate new GPG key
    echo -e "${BLUE}Generating new GPG key...${NC}"
    echo -e "${BLUE}Please follow the prompts to create your key:${NC}"
    echo -e "${BLUE}Recommended settings:${NC}"
    echo "  - Key type: RSA and RSA"
    echo "  - Key size: 4096 bits"
    echo "  - Key validity: 0 (never expires)"
    echo "  - Real name: $MAINTAINER_NAME"
    echo "  - Email: $MAINTAINER_EMAIL"
    
    if ! gpg --full-generate-key; then
        echo -e "${RED}Failed to generate GPG key${NC}"
        exit 1
    fi
    
    # Get the newly generated key ID
    GPG_KEY=$(gpg --list-secret-keys --keyid-format LONG "$MAINTAINER_EMAIL" | grep sec | tail -n1 | awk '{print $2}' | cut -d'/' -f2)
    
    if [ -z "$GPG_KEY" ]; then
        echo -e "${RED}Failed to get GPG key ID${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}GPG key generated successfully${NC}"
    echo -e "${BLUE}Your GPG key ID is:${NC} $GPG_KEY"
    
    # Export public key
    echo -e "${BLUE}Exporting public key...${NC}"
    gpg --armor --export "$GPG_KEY" > "${GPG_KEY}.asc"
    echo -e "${GREEN}Public key exported to ${GPG_KEY}.asc${NC}"
    
    # Upload to Ubuntu keyserver
    echo -e "${BLUE}Uploading key to Ubuntu keyserver...${NC}"
    if ! gpg --keyserver keyserver.ubuntu.com --send-keys "$GPG_KEY"; then
        echo -e "${RED}Failed to upload key to keyserver${NC}"
        echo -e "${BLUE}You may need to upload it manually at:${NC}"
        echo "https://keyserver.ubuntu.com/"
    else
        echo -e "${GREEN}Key uploaded to keyserver${NC}"
    fi
    
    # Save the key ID to config
    save_config
    
    echo -e "${BLUE}Important:${NC}"
    echo "1. Save your key ID: $GPG_KEY"
    echo "2. Import your public key to Launchpad: ${GPG_KEY}.asc"
    echo "3. Wait a few minutes for the key to propagate to the keyserver"
}

# Function to setup git repository
setup_git_repo() {
    local SOURCE_DIR=$1
    local BUILD_DIR=$2
    
    echo -e "${BLUE}Setting up Git repository...${NC}"
    
    # Initialize git in the build directory
    cd "$BUILD_DIR"
    
    # Check if git is installed
    if ! command -v git &> /dev/null; then
        echo -e "${BLUE}Installing git...${NC}"
        if [ "$EUID" -ne 0 ]; then
            sudo apt-get update && sudo apt-get install -y git
        else
            apt-get update && apt-get install -y git
        fi
    fi
    
    # Initialize git repository
    git init
    
    # Create .gitignore
    cat > .gitignore << EOF
*.o
*.so
*.a
*.deb
*.changes
*.build
*.buildinfo
*.dsc
*.tar.gz
*.tar.xz
debian/.debhelper/
debian/debhelper-build-stamp
debian/files
debian/*.substvars
debian/*.log
debian/$PACKAGE_NAME/
debian/tmp/
obj-*/
EOF
    
    # Add all files
    git add .
    git config user.name "$MAINTAINER_NAME"
    git config user.email "$MAINTAINER_EMAIL"
    git commit -m "Initial commit for $PACKAGE_NAME $PACKAGE_VERSION"
    
    echo -e "${GREEN}Git repository initialized${NC}"
}

# Function to setup Launchpad repository
setup_launchpad_repo() {
    local BUILD_DIR=$1
    
    echo -e "${BLUE}Setting up Launchpad repository...${NC}"
    
    # Check if bzr is installed (needed for Launchpad)
    if ! command -v bzr &> /dev/null; then
        echo -e "${BLUE}Installing bzr...${NC}"
        if [ "$EUID" -ne 0 ]; then
            sudo apt-get update && sudo apt-get install -y bzr
        else
            apt-get update && apt-get install -y bzr
        fi
    fi
    
    # Create Launchpad repository
    echo -e "${BLUE}Creating Launchpad repository...${NC}"
    local REPO_NAME="~$LAUNCHPAD_USERNAME/$PACKAGE_NAME"
    
    # Try to create the project on Launchpad using the API
    echo -e "${BLUE}Creating project on Launchpad...${NC}"
    echo -e "${BLUE}Please visit:${NC}"
    echo "https://launchpad.net/projects/+new"
    echo -e "${BLUE}And create a project with these details:${NC}"
    echo "Name: $PACKAGE_NAME"
    echo "Title: $PACKAGE_DESCRIPTION"
    echo "Summary: $PACKAGE_DESCRIPTION"
    read -p "Press Enter once you've created the project..."
    
    # Setup Git repository on Launchpad
    echo -e "${BLUE}Setting up Git repository on Launchpad...${NC}"
    echo -e "${BLUE}Please visit:${NC}"
    echo "https://code.launchpad.net/$PACKAGE_NAME/+git/+new"
    echo -e "${BLUE}And create a Git repository with these details:${NC}"
    echo "Repository name: $PACKAGE_NAME"
    read -p "Press Enter once you've created the repository..."
    
    # Add Launchpad remote
    cd "$BUILD_DIR"
    git remote add origin "git+ssh://$LAUNCHPAD_USERNAME@git.launchpad.net/~$LAUNCHPAD_USERNAME/$PACKAGE_NAME"
    
    # Push to Launchpad
    echo -e "${BLUE}Pushing to Launchpad...${NC}"
    if ! git push -u origin master; then
        echo -e "${RED}Failed to push to Launchpad${NC}"
        echo -e "${BLUE}Please ensure:${NC}"
        echo "1. You have uploaded your SSH key to Launchpad"
        echo "2. You have the correct permissions"
        echo "3. The repository name is correct"
        return 1
    fi
    
    echo -e "${GREEN}Repository setup complete!${NC}"
    echo -e "${BLUE}Your repository is available at:${NC}"
    echo "https://code.launchpad.net/~$LAUNCHPAD_USERNAME/$PACKAGE_NAME"
    return 0
}

# Function to install build dependencies
install_build_deps() {
    local CONTROL_FILE="$1/debian/control"
    if [ ! -f "$CONTROL_FILE" ]; then
        echo -e "${RED}Error: debian/control file not found${NC}"
        return 1
    fi
    
    echo -e "${BLUE}Installing build dependencies...${NC}"
    
    # First, make sure we have the tools we need
    if ! command -v mk-build-deps >/dev/null 2>&1; then
        echo -e "${BLUE}Installing devscripts and equivs...${NC}"
        echo "This will require sudo access to install packages."
        if ! sudo apt-get install -y devscripts equivs; then
            echo -e "${RED}Error: Failed to install required tools${NC}"
            return 1
        fi
    fi
    
    # Install basic build dependencies first
    echo -e "${BLUE}Installing basic build dependencies...${NC}"
    if ! sudo apt-get install -y build-essential cmake; then
        echo -e "${RED}Error: Failed to install basic build dependencies${NC}"
        return 1
    fi
    
    # Extract Build-Depends line from control file
    local BUILD_DEPS=$(grep "^Build-Depends:" "$CONTROL_FILE" | sed 's/Build-Depends: //')
    
    if [ -z "$BUILD_DEPS" ]; then
        echo -e "${YELLOW}No additional build dependencies found in control file${NC}"
        return 0
    fi
    
    echo -e "${BLUE}Found build dependencies: $BUILD_DEPS${NC}"
    echo "This will require sudo access to install packages."
    
    # Create a temporary control file with just the build dependencies
    local TEMP_CONTROL=$(mktemp)
    cat > "$TEMP_CONTROL" << EOF
Package: ${PACKAGE_NAME}-build-deps
Source: ${PACKAGE_NAME}-build-deps
Version: 1.0
Architecture: all
Build-Depends: ${BUILD_DEPS}
Description: Build dependencies for ${PACKAGE_NAME}
EOF
    
    # Use equivs to create and install the build dependencies
    cd "$(dirname "$TEMP_CONTROL")"
    if ! equivs-build "$TEMP_CONTROL"; then
        echo -e "${RED}Error: Failed to create build dependencies package${NC}"
        rm -f "$TEMP_CONTROL"
        return 1
    fi
    
    if ! sudo dpkg -i ./*.deb; then
        echo -e "${RED}Error: Failed to install build dependencies package${NC}"
        rm -f "$TEMP_CONTROL" ./*.deb
        return 1
    fi
    
    # Clean up
    rm -f "$TEMP_CONTROL" ./*.deb
    
    return 0
}

# Main script
echo -e "${BLUE}PPA Builder - Create and upload Debian packages to Launchpad${NC}"

# Check dependencies
check_dependencies

# Get user information
get_user_info

# Setup GPG key
setup_gpg

# Get source directory
echo -e "${BLUE}Source Directory Setup${NC}"
SOURCE_DIR=""
while [ ! -d "$SOURCE_DIR" ]; do
    read -p "Enter the source directory path: " SOURCE_DIR_INPUT
    
    # Skip if empty
    if [ -z "$SOURCE_DIR_INPUT" ]; then
        continue
    fi
    
    # Convert to absolute path if relative
    if [[ "$SOURCE_DIR_INPUT" = /* ]]; then
        SOURCE_DIR="$SOURCE_DIR_INPUT"
    else
        # Use current directory as base
        SOURCE_DIR="$PWD/$SOURCE_DIR_INPUT"
    fi
    
    # Clean up the path (remove ./ and ../)
    SOURCE_DIR="$(cd "$SOURCE_DIR" 2>/dev/null && pwd || echo "$SOURCE_DIR")"
    
    if [ ! -d "$SOURCE_DIR" ]; then
        echo -e "${RED}Error: Directory does not exist: $SOURCE_DIR${NC}"
        SOURCE_DIR=""
    fi
done

# Validate source directory
validate_source "$SOURCE_DIR"

# Get package information
get_package_info

# Create debian directory structure
create_debian_dir "$SOURCE_DIR" "$PACKAGE_NAME" "$PACKAGE_VERSION" "$PACKAGE_DESCRIPTION"

# Install build dependencies
install_build_deps "$SOURCE_DIR"
if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to install build dependencies${NC}"
    exit 1
fi

# Create package structure
create_debian_structure "$SOURCE_DIR"

# Setup Git repository
setup_git_repo "$SOURCE_DIR" "/tmp/ppa_build/${PACKAGE_NAME}-${PACKAGE_VERSION}"

# Setup Launchpad repository
setup_launchpad_repo "/tmp/ppa_build/${PACKAGE_NAME}-${PACKAGE_VERSION}"

# Upload to PPA
upload_to_ppa

# Add PPA to system
read -p "Would you like to add this PPA to your system? (Y/n): " ADD_PPA
if [[ $ADD_PPA =~ ^[Yy]?$ ]]; then
    add_ppa_to_system
fi

echo -e "${GREEN}Process complete!${NC}"
echo -e "${BLUE}Important notes:${NC}"
echo "1. Make sure your GPG key is properly set up on Launchpad"
echo "2. Check your PPA page for build status: https://launchpad.net/~$LAUNCHPAD_USERNAME/+archive/ubuntu/$PACKAGE_NAME"
echo "3. The build process may take some time"
echo "4. Your Git repository is at: https://code.launchpad.net/~$LAUNCHPAD_USERNAME/$PACKAGE_NAME"
if [[ $ADD_PPA =~ ^[Yy]?$ ]]; then
    echo "5. Once the package is built, you can install it with: sudo apt-get install $PACKAGE_NAME"
fi
