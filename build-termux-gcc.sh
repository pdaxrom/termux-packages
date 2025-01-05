#! /bin/bash
# N64 MIPS GCC toolchain build/install script for Unix distributions
# (c) 2012-2024 DragonMinded and libDragon Contributors.
# See the root folder for license information.

# Bash strict mode http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

# Check that TOOLCHAIN_INST is defined
#if [ -z "${TOOLCHAIN_INST-}" ]; then
#    echo "TOOLCHAIN_INST environment variable is not defined."
#    echo "Please define TOOLCHAIN_INST and point it to the requested installation directory"
#    exit 1
#fi

TOP_DIR=$PWD

BUILD_TARGET=aarch64-linux-android

TOOLCHAIN_INST=$PREFIX

#SYSROOT=${TOOLCHAIN_INST}/${BUILD_TARGET}/lib
SYSROOT=$(dirname ${PREFIX})

# Path where the toolchain will be built.
BUILD_PATH="${BUILD_PATH:-toolchain}"

TMPINST_DIR="$(realpath ${BUILD_PATH})/tmpinst"
test -d $TMPINST_DIR || mkdir -p $TMPINST_DIR

REPO_DIR=${TOP_DIR}/out-$(uname -m)
test -d $REPO_DIR || mkdir -p $REPO_DIR

# Defines the build system variables to allow cross compilation.
ARM_BUILD=${ARM_BUILD:-""}
ARM_HOST=${ARM_HOST:-""}
ARM_TARGET=${ARM_TARGET:-arm-none-eabi}

# Set TOOLCHAIN_INST before calling the script to change the default installation directory path
INSTALL_PATH="${TOOLCHAIN_INST}"
# Set PATH for newlib to compile using GCC for MIPS N64 (pass 1)
export PATH="$PATH:$INSTALL_PATH/bin"

# Determine how many parallel Make jobs to run based on CPU count
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN)}"
JOBS="${JOBS:-1}" # If getconf returned nothing, default to 1

JOBS=3

# GCC configure arguments to use system GMP/MPC/MFPF
GCC_CONFIGURE_ARGS=()

# Dependency source libs (Versions)
GCC_V=14.2.0
GMP_V=6.3.0 
MPC_V=1.3.1 
MPFR_V=4.2.1

# Check if a command-line tool is available: status 0 means "yes"; status 1 means "no"
command_exists () {
    (command -v "$1" >/dev/null 2>&1)
    return $?
}

# Download the file URL using wget or curl (depending on which is installed)
download () {
    if   command_exists wget ; then wget -c  "$1"
    elif command_exists curl ; then curl -LO "$1"
    else
        echo "Install wget or curl to download toolchain sources" 1>&2
        return 1
    fi
}

patching () {
    pushd $1
    if [ ! -e .patched ]; then
        find $TOP_DIR/patches -name "*-${1}.patch" | while read f; do
            patch -p1 < $f
        done
        touch .patched
    fi
    popd
}

packing () {
    local PKG_SIZE=$(du -k ${TMPINST_DIR}/${PKG} | tail -1 | awk '{ print $1}')
    local DEB_ARCH=$(uname -m)

    mkdir ${TMPINST_DIR}/${PKG}/DEBIAN

    cat > ${TMPINST_DIR}/${PKG}/DEBIAN/control <<EOF
Package: $PKG
Architecture: $DEB_ARCH
Installed-Size: $PKG_SIZE
Maintainer: $PKG_MAINTAINER
Version: ${PKG_VERSION}${PKG_SUBVERSION}
Homepage: $PKG_HOME
Depends: $PKG_DEPS
Description: $PKG_DESC
EOF

    chmod 644 ${TMPINST_DIR}/${PKG}/DEBIAN/control
    chmod 755 ${TMPINST_DIR}/${PKG}/DEBIAN

    dpkg -b ${TMPINST_DIR}/${PKG} ${REPO_DIR}/${PKG}_${PKG_VERSION}${PKG_SUBVERSION}_${DEB_ARCH}.deb
}

# Compilation on macOS via homebrew
if [[ $OSTYPE == 'darwin'* ]]; then
    if ! command_exists brew; then
        echo "Compilation on macOS is supported via Homebrew (https://brew.sh)"
        echo "Please install homebrew and try again"
        exit 1
    fi

    # Install required dependencies. gsed is really required, the others are optionals
    # and just speed up build.
    brew install -q gmp mpfr libmpc gsed gcc isl libpng lz4 make mpc texinfo zlib

    # FIXME: we could avoid download/symlink GMP and friends for a cross-compiler
    # but we need to symlink them for the canadian compiler.
    #GMP_V=""
    #MPC_V=""
    #MPFR_V=""

    # Tell GCC configure where to find the dependent libraries
    GCC_CONFIGURE_ARGS=(
        "--with-gmp=$(brew --prefix)"
        "--with-mpfr=$(brew --prefix)"
        "--with-mpc=$(brew --prefix)"
        "--with-zlib=$(brew --prefix)"
    )

    # Install GNU sed as default sed in PATH. GCC compilation fails otherwise,
    # because it does not work with BSD sed.
    PATH="$(brew --prefix gsed)/libexec/gnubin:$PATH"
    export PATH
else
    # Configure GCC arguments for non-macOS platforms
    GCC_CONFIGURE_ARGS+=("--with-system-zlib")
fi
# Create build path and enter it
mkdir -p "$BUILD_PATH"
cd "$BUILD_PATH"

# Dependency downloads and unpack
test -f "gcc-$GCC_V.tar.gz"           || download "https://ftp.gnu.org/gnu/gcc/gcc-$GCC_V/gcc-$GCC_V.tar.gz"
test -d "gcc-$GCC_V"                  || tar -xzf "gcc-$GCC_V.tar.gz"

patching "gcc-$GCC_V"

if [ "$GMP_V" != "" ]; then
    test -f "gmp-$GMP_V.tar.bz2"           || download "https://ftp.gnu.org/gnu/gmp/gmp-$GMP_V.tar.bz2"
    test -d "gmp-$GMP_V"                  || tar -xf "gmp-$GMP_V.tar.bz2" # note: no .gz download file currently available

    patching "gmp-$GMP_V"

    pushd "gcc-$GCC_V"
    ln -sf ../"gmp-$GMP_V" "gmp"
    popd
fi

if [ "$MPC_V" != "" ]; then
    test -f "mpc-$MPC_V.tar.gz"           || download "https://ftp.gnu.org/gnu/mpc/mpc-$MPC_V.tar.gz"
    test -d "mpc-$MPC_V"                  || tar -xzf "mpc-$MPC_V.tar.gz"

    patching "mpc-$MPC_V"

    pushd "gcc-$GCC_V"
    ln -sf ../"mpc-$MPC_V" "mpc"
    popd
fi

if [ "$MPFR_V" != "" ]; then
    test -f "mpfr-$MPFR_V.tar.gz"         || download "https://ftp.gnu.org/gnu/mpfr/mpfr-$MPFR_V.tar.gz"
    test -d "mpfr-$MPFR_V"                || tar -xzf "mpfr-$MPFR_V.tar.gz"

    patching "mpfr-$MPFR_V"

    pushd "gcc-$GCC_V"
    ln -sf ../"mpfr-$MPFR_V" "mpfr"
    popd
fi

test -d gcc-build || mkdir gcc-build
pushd gcc-build

if [ ! -d ${TOOLCHAIN_INST}/${BUILD_TARGET}/include/android ] && [ ! -e ${TOOLCHAIN_INST}/${BUILD_TARGET}/include/string.h ] && [ ! -e .gcc_inc_fix ]; then
    mkdir -p ${TOOLCHAIN_INST}/${BUILD_TARGET}/include
    cp -rf ${TOP_DIR}/fixes/ndk-sysroot/include/android ${TOP_DIR}/fixes/ndk-sysroot/include/string.h ${TOOLCHAIN_INST}/${BUILD_TARGET}/include
    ln -sf ../../include/${BUILD_TARGET}/asm ${TOOLCHAIN_INST}/${BUILD_TARGET}/include/asm

    touch .gcc_inc_fix
fi

if [ ! -e .configured ]; then
    mkdir gcc

    cat >gcc/config.cache<<EOF
ac_cv_c_bigendian=no
gcc_cv_c_no_fpie=no
gcc_cv_no_pie=no
ac_cv_func_getloadavg=no
ac_cv_func_aligned_alloc=no
ac_cv_func_timespec_get=no
EOF

    ../gcc-${GCC_V}/configure \
    --with-pkgversion='pdaXrom Termux packages 1.0' \
    --with-gcc-major-version-only \
    --program-suffix=-${GCC_V/.*} \
    --build=${BUILD_TARGET} \
    --host=${BUILD_TARGET} \
    --target=${BUILD_TARGET} \
    --prefix=${TOOLCHAIN_INST} \
    --libexecdir=${TOOLCHAIN_INST}/lib \
    --with-sysroot=$SYSROOT \
    --with-build-sysroot=$SYSROOT \
    --with-gnu-as \
    --with-gnu-ld \
    --enable-languages=c,c++,fortran,objc,obj-c++ \
    --enable-bionic-libs \
    --enable-libatomic-ifuncs=no \
    --enable-cloog-backend=isl \
    --disable-libssp \
    --enable-threads \
    --disable-libmudflap \
    --disable-sjlj-exceptions \
    --disable-tls \
    --disable-libitm \
    --enable-initfini-array \
    --disable-nls \
    --disable-bootstrap \
    --disable-libquadmath \
    --enable-plugins \
    --enable-libgomp \
    --disable-libsanitizer \
    --enable-graphite=yes \
    --enable-objc-gc=auto \
    --enable-eh-frame-hdr-for-static \
    --enable-target-optspace \
    --with-host-libstdcxx='-static-libgcc -Wl,-Bstatic,-lstdc++,-Bdynamic -lm' \
    --enable-fix-cortex-a53-835769 \
    --enable-default-pie \
    --without-system-zlib \
    --without-zstd \
    --disable-shared \
    CPPFLAGS='-O2 -D__ANDROID_API__=29' \
    CFLAGS='-O2 -D__ANDROID_API__=29' \
    CXXFLAGS='-O2 -D__ANDROID_API__=29' \
    AS="as" \
    AS_FOR_TARGET="as" \
    CC="gcc-14" \
    CXX="g++-14" \
    CPP="cpp-14"

    touch .configured
fi

if [ ! -e .compiled ]; then
    make -j "$JOBS"

    touch .compiled
fi

if [ ! -e .packed ]; then
    PKG=gcc-android
    PKG_VERSION=$GCC_V
    PKG_SUBVERSION=
    PKG_URL="http://mirrors.concertpass.com/gcc/releases/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
    PKG_MAINTAINER="sashz <sashz@pdaXrom.org>"
    PKG_HOME="https://gcc.gnu.org/"
    PKG_DESC="The GNU Compiler Collection"
    PKG_DEPS="binutils | binutils-android, ndk-sysroot"

    make install-strip DESTDIR=${TMPINST_DIR}/${PKG}

    mkdir -p ${TMPINST_DIR}/${PKG}/${TOOLCHAIN_INST}/${BUILD_TARGET}/include
    cp -rf ${TOP_DIR}/fixes/ndk-sysroot/include/android ${TOP_DIR}/fixes/ndk-sysroot/include/string.h ${TMPINST_DIR}/${PKG}/${TOOLCHAIN_INST}/${BUILD_TARGET}/include
    ln -sf ../../include/${BUILD_TARGET}/asm ${TMPINST_DIR}/${PKG}/${TOOLCHAIN_INST}/${BUILD_TARGET}/include/asm

    packing

    touch .packed
fi

if [ -e .gcc_inc_fix ]; then
    rm -rf ${TOOLCHAIN_INST}/${BUILD_TARGET}/include/android ${TOOLCHAIN_INST}/${BUILD_TARGET}/include/string.h ${TOOLCHAIN_INST}/${BUILD_TARGET}/include/asm

    rm -f .gcc_inc_fix
fi

popd

# Final message
echo
echo "***********************************************"
echo "Libdragon toolchain correctly built and installed"
echo "Installation directory: \"${TOOLCHAIN_INST}\""
echo "Build directory: \"${BUILD_PATH}\" (can be removed now)"
