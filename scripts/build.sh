#!/bin/sh
# Build script for audited bash - runs inside distro-specific Docker containers.
# Environment variables expected:
#   BASH_VER  - Bash version to build (e.g. 5.0)
#   PKG_MGR   - Package manager: apt, yum, or dnf
set -ex

# ============================================================
# 1. Install build dependencies
# ============================================================
if [ "$PKG_MGR" = "apt" ]; then
  export DEBIAN_FRONTEND=noninteractive
  # Handle EOL Ubuntu repos
  . /etc/os-release 2>/dev/null || true
  case "$VERSION_ID" in
    18.04|20.04)
      sed -i 's/archive.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list
      sed -i 's/security.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list
      ;;
  esac
  apt-get update
  apt-get install -y --no-install-recommends wget ca-certificates build-essential bison patch file

elif [ "$PKG_MGR" = "yum" ]; then
  # Handle CentOS 7 EOL repos
  sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null || true
  sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null || true
  yum install -y wget gcc make bison patch file diffutils

elif [ "$PKG_MGR" = "dnf" ]; then
  dnf install -y wget gcc make bison patch file diffutils
fi

# ============================================================
# 2. Download and extract bash source
# ============================================================
cd /workspace
TARBALL="bash-${BASH_VER}.tar.gz"

# Use cached tarball if available, otherwise download
if [ ! -f "cache/${TARBALL}" ]; then
  mkdir -p cache
  wget -q "https://ftp.gnu.org/gnu/bash/${TARBALL}" -O "cache/${TARBALL}"
fi
tar -xzf "cache/${TARBALL}"
cd "bash-${BASH_VER}"

# ============================================================
# 3. Apply audit patch
# ============================================================
patch -p0 --fuzz=3 < /workspace/bash_audit.patch

# ============================================================
# 4. Configure and build
# ============================================================
./configure --without-bash-malloc --disable-nls
make -j"$(nproc 2>/dev/null || echo 2)"

# ============================================================
# 5. Verify and copy output
# ============================================================
./bash --version || true
cp bash /workspace/bash-output
echo "Build successful: bash-${BASH_VER}"