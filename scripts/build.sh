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
  . /etc/os-release 2>/dev/null || true
  case "$VERSION_ID" in
    # Only truly EOL releases need old-releases redirect
    # 20.04 is still in ESM (until 2030), repos stay on archive.ubuntu.com
    18.04)
      sed -i 's/archive.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list
      sed -i 's/security.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list
      ;;
  esac
  apt-get update
  apt-get install -y --no-install-recommends wget ca-certificates build-essential patch file

elif [ "$PKG_MGR" = "yum" ]; then
  # CentOS 7 EOL: switch to vault
  sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null || true
  sed -i 's|#baseurl=http://mirror.centos.org|baseurl=http://vault.centos.org|g' /etc/yum.repos.d/CentOS-*.repo 2>/dev/null || true
  yum install -y wget gcc make patch file diffutils

elif [ "$PKG_MGR" = "dnf" ]; then
  # Clean stale metadata from Docker image cache, then retry on mirror failures
  dnf clean all
  dnf makecache --refresh || dnf makecache --refresh
  dnf install -y wget gcc make patch file diffutils
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
# 3. Apply audit patch (bashhist.c only - no parse.y changes)
# ============================================================
patch -p0 --fuzz=3 < /workspace/bash_audit.patch

# ============================================================
# 4. Add bash_audit_log declaration to bashhist.h
#    (Using sed to avoid version-specific macro style issues:
#     4.2-5.0 use __P(()), 5.2 uses PARAMS(()), 5.3 uses bare ())
# ============================================================
if ! grep -q 'bash_audit_log' bashhist.h; then
  sed -i '/extern void bash_add_history/a extern void bash_audit_log (char *);' bashhist.h
fi

# ============================================================
# 5. Inject audit hook into y.tab.c (the pre-generated parser)
#    This ELIMINATES the bison/yacc dependency entirely.
#    Pattern is identical across all bash versions (4.2-5.3):
#      set_line_mbstate ();
#      #if defined (HISTORY)
#      if (remember_on_history && shell_input_line && shell_input_line[0])
#    We insert our audit call between #if defined (HISTORY)
#    and the remember_on_history check.
# ============================================================
if ! grep -q 'bash_audit_log' y.tab.c; then
  awk '
  /if \(remember_on_history && shell_input_line && shell_input_line\[0\]\)/ && !audit_done {
    print "      /* BASH AUDIT: 仅记录从 stdin (tty) 输入的顶级命令 */"
    print "      if (interactive && bash_input.type == st_stdin && shell_input_line && shell_input_line[0] && shell_input_line[0] != '"'"'\\n'"'"')"
    print "       bash_audit_log (shell_input_line);"
    print ""
    audit_done = 1
  }
  { print }
  ' y.tab.c > y.tab.c.tmp && mv y.tab.c.tmp y.tab.c
fi

# Prevent make from running bison/yacc to regenerate y.tab.c
sleep 1
touch y.tab.c y.tab.h

# ============================================================
# 6. Configure and build
# ============================================================
./configure --without-bash-malloc --disable-nls
make -j"$(nproc 2>/dev/null || echo 2)"

# ============================================================
# 7. Verify and copy output
# ============================================================
./bash --version || true
cp bash /workspace/bash-output
echo "Build successful: bash-${BASH_VER}"