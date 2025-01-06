#! /bin/bash
# N64 MIPS GCC toolchain build/install script for Unix distributions
# (c) 2012-2024 DragonMinded and libDragon Contributors.
# See the root folder for license information.

# Bash strict mode http://redsymbol.net/articles/unofficial-bash-strict-mode/
set -euo pipefail
IFS=$'\n\t'

ARM_INST=$PREFIX

unset PREFIX

# Check that ARM_INST is defined
if [ -z "${ARM_INST-}" ]; then
    echo "ARM_INST environment variable is not defined."
    echo "Please define ARM_INST and point it to the requested installation directory"
    exit 1
fi

TOOLCHAIN_INST=$ARM_INST

TOP_DIR=$PWD

# Path where the toolchain will be built.
BUILD_PATH="${BUILD_PATH:-toolchain}"

TMPINST_DIR="$(realpath ${BUILD_PATH}/tmpinst)"
test -d $TMPINST_DIR || mkdir -p $TMPINST_DIR

REPO_DIR=${TOP_DIR}/out-$(uname -m)
test -d $REPO_DIR || mkdir -p $REPO_DIR

# Defines the build system variables to allow cross compilation.
ARM_BUILD=${ARM_BUILD:-""}
ARM_HOST=${ARM_HOST:-""}
ARM_TARGET=${ARM_TARGET:-arm-none-eabi}

# Set ARM_INST before calling the script to change the default installation directory path
INSTALL_PATH="${ARM_INST}"
# Set PATH for newlib to compile using GCC for MIPS N64 (pass 1)
export PATH="$PATH:$INSTALL_PATH/bin"

# Determine how many parallel Make jobs to run based on CPU count
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN)}"
JOBS="${JOBS:-1}" # If getconf returned nothing, default to 1

JOBS=3

# GCC configure arguments to use system GMP/MPC/MFPF
GCC_CONFIGURE_ARGS=()

# Dependency source libs (Versions)
BINUTILS_V=2.43.1
GCC_V=14.2.0
NEWLIB_V=4.4.0.20231231
GMP_V=6.3.0
MPC_V=1.3.1
MPFR_V=4.2.1
MAKE_V=${MAKE_V:-""}

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
test -f "binutils-$BINUTILS_V.tar.gz" || download "https://ftp.gnu.org/gnu/binutils/binutils-$BINUTILS_V.tar.gz"
test -d "binutils-$BINUTILS_V"        || tar -xzf "binutils-$BINUTILS_V.tar.gz"

patching "binutils-$BINUTILS_V"

test -f "gcc-$GCC_V.tar.gz"           || download "https://ftp.gnu.org/gnu/gcc/gcc-$GCC_V/gcc-$GCC_V.tar.gz"
test -d "gcc-$GCC_V"                  || tar -xzf "gcc-$GCC_V.tar.gz"

patching "gcc-$GCC_V"

test -f "newlib-$NEWLIB_V.tar.gz"     || download "https://sourceware.org/pub/newlib/newlib-$NEWLIB_V.tar.gz"
test -d "newlib-$NEWLIB_V"            || tar -xzf "newlib-$NEWLIB_V.tar.gz"

patching "newlib-$NEWLIB_V"

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

if [ "$MAKE_V" != "" ]; then
    test -f "make-$MAKE_V.tar.gz"       || download "https://ftp.gnu.org/gnu/make/make-$MAKE_V.tar.gz"
    test -d "make-$MAKE_V"              || tar -xzf "make-$MAKE_V.tar.gz"

    patching "make-$MAKE_V"
fi

# Deduce build triplet using config.guess (if not specified)
# This is by the definition the current system so it should be OK.
if [ "$ARM_BUILD" == "" ]; then
    ARM_BUILD=$("binutils-$BINUTILS_V"/config.guess)
fi

if [ "$ARM_HOST" == "" ]; then
    ARM_HOST="$ARM_BUILD"
fi


if [ "$ARM_BUILD" == "$ARM_HOST" ]; then
    # Standard cross.
    CROSS_PREFIX=$INSTALL_PATH
else
    # Canadian cross.
    # The standard BUILD->TARGET cross-compiler will be installed into a separate prefix, as it is not
    # part of the distribution.
    mkdir -p cross_prefix
    CROSS_PREFIX="$(cd "$(dirname -- "cross_prefix")" >/dev/null; pwd -P)/$(basename -- "cross_prefix")"
    # "
    PATH="$CROSS_PREFIX/bin:$PATH"
    export PATH

    # Instead, the HOST->TARGET cross-compiler can be installed into the final installation path
    CANADIAN_PREFIX=$INSTALL_PATH

    # We need to build a canadian toolchain.
    # First we need a host compiler, that is binutils+gcc targeting the host. For instance,
    # when building a Libdragon Windows toolchain from Linux, this would be x86_64-w64-ming32,
    # that is, a compiler that we run that generates Windows executables.
    # Check if a host compiler is available. If so, we can just skip this step.
    if command_exists "$ARM_HOST"-gcc; then
        echo Found host compiler: "$ARM_HOST"-gcc in PATH. Using it.
    else
        if [ "$ARM_HOST" == "x86_64-w64-mingw32" ]; then
            echo This script requires a working Windows cross-compiler.
            echo We could build it for you, but it would make the process even longer.
            echo Install it instead:
            echo "  * Linux (Debian/Ubuntu): apt install mingw-w64"
            echo "  * macOS: brew install mingw-w64"
            exit 1
        else
            echo "Unimplemented option: we support building a Windows toolchain only, for now."
        fi
    fi
fi

# Compile BUILD->TARGET binutils
test -d binutils_compile_target || mkdir -p binutils_compile_target
pushd binutils_compile_target

if [ ! -e .configured ]; then
    mkdir bfd binutils

    cat >bfd/config.cache<<EOF
ac_cv_func_fopen64=no
ac_cv_func_fseeko64=no
ac_cv_func_ftello64=no
EOF

    cat >binutils/config.cache<<EOF
ac_cv_func_fopen64=no
ac_cv_func_fseeko64=no
ac_cv_func_ftello64=no
EOF

    ../"binutils-$BINUTILS_V"/configure \
    --prefix="$INSTALL_PATH" \
    --target="$ARM_TARGET" \
    --enable-multilib \
    --without-system-zlib \
    --without-zstd \
    --disable-werror \
    CPPFLAGS='-O2 -D__ANDROID_API__=29' \
    CFLAGS='-O2 -D__ANDROID_API__=29' \
    CXXFLAGS='-O2 -D__ANDROID_API__=29' \
    CC="gcc-14" \
    CXX="g++-14" \
    CPP="cpp-14"

    touch .configured
fi

if [ ! -e .compiled ]; then
    make -j "$JOBS"

    touch .compiled
fi

#if [ ! -e .installed ]; then
#    make install-strip
#
#    touch .installed
#fi

if [ ! -e .packed ]; then
    PKG=${ARM_TARGET}-binutils
    PKG_VERSION=$BINUTILS_V
    PKG_SUBVERSION=
    PKG_URL="https://mirror.kumi.systems/gnu/binutils/binutils-${PKG_VERSION}.tar.xz"
    PKG_DESC="GNU assembler, linker and binary utilities for ${ARM_TARGET}"
    PKG_MAINTAINER="sashz <sashz@pdaXrom.org>"
    PKG_HOME="https://www.gnu.org/software/binutils/"
    PKG_DEPS=""

    make install-strip DESTDIR=${TMPINST_DIR}/${PKG}

    rm -rf ${TMPINST_DIR}/${PKG}/data/data/com.termux/files/usr/lib/bfd-plugins
    rm -rf ${TMPINST_DIR}/${PKG}/data/data/com.termux/files/usr/share/info

    pushd ${TMPINST_DIR}/${PKG}/${TOOLCHAIN_INST}/${ARM_TARGET}/bin
    for f in $(find . -type f -exec basename {} \;); do
        ln -sf ../${ARM_TARGET}/bin/$f ../../bin/${ARM_TARGET}-$f
    done
    cd ../../bin

    popd

    packing

    dpkg -i ${REPO_DIR}/${PKG}_${PKG_VERSION}${PKG_SUBVERSION}_$(uname -m).deb

    touch .packed
fi

popd

# Compile GCC for MIPS N64.
# We need to build the C++ compiler to build the target libstd++ later.
test -d gcc_compile_target || mkdir -p gcc_compile_target
pushd gcc_compile_target

if [ ! -e .configured ]; then
    mkdir gcc

    cat >gcc/config.cache<<EOF
ac_cv_c_bigendian=no
gcc_cv_c_no_fpie=no
gcc_cv_no_pie=no
EOF

    ../"gcc-$GCC_V"/configure "${GCC_CONFIGURE_ARGS[@]}" \
    --with-pkgversion='pdaXrom Termux packages 1.0' \
    --prefix="$CROSS_PREFIX" \
    --target="$ARM_TARGET" \
    --enable-languages=c,c++,lto \
    --without-headers \
    --disable-libssp \
    --enable-multilib \
    --with-multilib-list=rmprofile,aprofile \
    --disable-shared \
    --with-gcc \
    --with-newlib \
    --enable-tls \
    --disable-threads \
    --disable-decimal-float \
    --disable-libffi \
    --disable-libgomp \
    --disable-libmudflap \
    --disable-libquadmath \
    --disable-win32-registry \
    --disable-nls \
    --disable-werror \
    --without-system-zlib \
    --without-zstd \
    --enable-host-pie \
    CC="gcc-14 -D__ANDROID_API__=29" \
    CXX="g++-14 -D__ANDROID_API__=29" \
    CPP="cpp-14 -D__ANDROID_API__=29"

    touch .configured
fi

if [ ! -e .gcc_compiled ]; then
    make all-gcc -j "$JOBS"

    touch .gcc_compiled
fi

if [ ! -e .gcc_installed ]; then
    make install-gcc

    touch .gcc_installed
fi

if [ ! -e .libgcc_compiled ]; then
    make all-target-libgcc -j "$JOBS"

    touch .libgcc_compiled
fi

if [ ! -e .libgcc_installed ]; then
    make install-target-libgcc

    touch .libgcc_installed
fi

popd

# Compile newlib for target.
test -d newlib_compile_target || mkdir -p newlib_compile_target
pushd newlib_compile_target

if [ ! -e .configured ]; then
    CFLAGS_FOR_TARGET="-DHAVE_ASSERT_FUNC -O2 -fpermissive" ../"newlib-$NEWLIB_V"/configure \
    --prefix="$CROSS_PREFIX" \
    --target="$ARM_TARGET" \
    --disable-newlib-supplied-syscalls \
    --disable-threads \
    --disable-libssp \
    --disable-werror

    touch .configured
fi

if [ ! -e .compiled ]; then
    make -j "$JOBS"

    touch .compiled
fi

if [ ! -e .packed ]; then
    PKG=${ARM_TARGET}-newlib
    PKG_VERSION=$NEWLIB_V
    PKG_SUBVERSION=
    PKG_URL="https://sourceware.org/pub/newlib/newlib-${PKG_VERSION}.tar.gz"
    PKG_DESC="Newlib is a C library intended for use on embedded systems. Compiled for ${ARM_TARGET}."
    PKG_MAINTAINER="sashz <sashz@pdaXrom.org>"
    PKG_HOME="https://sourceware.org/newlib/"
    PKG_DEPS=""

    make install DESTDIR=${TMPINST_DIR}/${PKG}
    rm -rf ${TMPINST_DIR}/${PKG}/data/data/com.termux/files/usr/share/info

    packing

    dpkg -i ${REPO_DIR}/${PKG}_${PKG_VERSION}${PKG_SUBVERSION}_$(uname -m).deb

    touch .packed
fi

popd

# For a standard cross-compiler, the only thing left is to finish compiling the target libraries
# like libstd++. We can continue on the previous GCC build target.
if [ "$ARM_BUILD" == "$ARM_HOST" ]; then
    pushd gcc_compile_target

    if [ ! -e .gcc_compiled_target ]; then
        make all -j "$JOBS"

        touch .gcc_compiled_target
    fi

#    if [ ! -e .gcc_installed_target ]; then
#        make install-strip
#
#        touch .gcc_installed_target
#    fi

    if [ ! -e .packed ]; then
        PKG=${ARM_TARGET}-gcc
        PKG_VERSION=$GCC_V
        PKG_SUBVERSION=
        PKG_URL="http://mirrors.concertpass.com/gcc/releases/gcc-${PKG_VERSION}/gcc-${PKG_VERSION}.tar.xz"
        PKG_MAINTAINER="sashz <sashz@pdaXrom.org>"
        PKG_HOME="https://gcc.gnu.org/"
        PKG_DESC="The GNU Compiler Collection for ${ARM_TARGET}"
        PKG_DEPS="${ARM_TARGET}-binutils, ${ARM_TARGET}-newlib"

        make install-strip DESTDIR=${TMPINST_DIR}/${PKG}
        rm -rf ${TMPINST_DIR}/${PKG}/data/data/com.termux/files/usr/share/info
        rm -rf ${TMPINST_DIR}/${PKG}/data/data/com.termux/files/usr/share/man/man7
        rm -rf ${TMPINST_DIR}/${PKG}/data/data/com.termux/files/usr/lib64/libcc1.*

        packing

        dpkg -i ${REPO_DIR}/${PKG}_${PKG_VERSION}${PKG_SUBVERSION}_$(uname -m).deb

        touch .packed
    fi

    popd
else

echo "#2"
exit 0

    # Compile HOST->TARGET binutils
    # NOTE: we pass --without-msgpack to workaround a bug in Binutils, introduced
    # with this commit: https://sourceware.org/git/?p=binutils-gdb.git;a=commit;h=2952f10cd79af4645222f124f28c7928287d8113
    # This is due to the fact that pkg-config is used to activate compilation with msgpack
    # but that it is not correct in the case of a canadian cross.
    echo "Compiling binutils-$BINUTILS_V for foreign host"
    mkdir -p binutils_compile_host
    pushd binutils_compile_host

    mkdir bfd binutils

    cat >bfd/config.cache<<EOF
ac_cv_func_fopen64=no
ac_cv_func_fseeko64=no
ac_cv_func_ftello64=no
EOF

    cat >binutils/config.cache<<EOF
ac_cv_func_fopen64=no
ac_cv_func_fseeko64=no
ac_cv_func_ftello64=no
EOF

    ../"binutils-$BINUTILS_V"/configure \
        --prefix="$INSTALL_PATH" \
        --build="$ARM_BUILD" \
        --host="$ARM_HOST" \
        --target="$ARM_TARGET" \
        --enable-multilib \
        --disable-werror \
        --without-system-zlib \
        --without-zstd \
        --without-msgpack
    make -j "$JOBS"
    make install-strip || sudo make install-strip || su -c "make install-strip"
    popd

    # Compile HOST->TARGET gcc
    mkdir -p gcc_compile
    pushd gcc_compile

    mkdir gcc

    cat >gcc/config.cache<<EOF
ac_cv_c_bigendian=no
gcc_cv_c_no_fpie=no
gcc_cv_no_pie=no
EOF

    CFLAGS_FOR_TARGET="-O2" CXXFLAGS_FOR_TARGET="-O2" \
        ../"gcc-$GCC_V"/configure \
        --with-pkgversion='pdaXrom Termux packages 1.0' \
        --prefix="$INSTALL_PATH" \
        --target="$ARM_TARGET" \
        --build="$ARM_BUILD" \
        --host="$ARM_HOST" \
        --disable-werror \
        --enable-languages=c,c++,lto \
        --disable-libssp \
        --enable-multilib \
        --with-multilib-list=rmprofile,aprofile \
        --disable-shared \
        --with-gcc \
        --with-newlib \
        --enable-tls \
        --disable-threads \
        --disable-decimal-float \
        --disable-libffi \
        --disable-libgomp \
        --disable-libmudflap \
        --disable-libquadmath \
        --disable-win32-registry \
        --disable-nls \
        --without-system-zlib \
        --without-zstd \
        --enable-host-pie
    make all-target-libgcc -j "$JOBS"
    make install-target-libgcc || sudo make install-target-libgcc || su -c "make install-target-libgcc"
    popd

    # Compile newlib for target.
    mkdir -p newlib_compile
    pushd newlib_compile
    CFLAGS_FOR_TARGET="-DHAVE_ASSERT_FUNC -O2 -fpermissive" ../"newlib-$NEWLIB_V"/configure \
        --prefix="$INSTALL_PATH" \
        --target="$ARM_TARGET" \
        --disable-newlib-supplied-syscalls \
        --disable-threads \
        --disable-libssp \
        --disable-werror
    make -j "$JOBS"
    make install || sudo env PATH="$PATH" make install || su -c "env PATH=\"$PATH\" make install"
    popd

    # Finish compiling GCC
    mkdir -p gcc_compile
    pushd gcc_compile
    make all -j "$JOBS"
    make install-strip || sudo make install-strip || su -c "make install-strip"
    popd
fi

if [ "$MAKE_V" != "" ]; then
    pushd "make-$MAKE_V"
    ./configure \
      --prefix="$INSTALL_PATH" \
        --disable-largefile \
        --disable-nls \
        --disable-rpath \
        --build="$ARM_BUILD" \
        --host="$ARM_HOST"
    make -j "$JOBS"
    make install-strip || sudo make install-strip || su -c "make install-strip"
    popd
fi

# Final message
echo
echo "***********************************************"
echo "Libdragon toolchain correctly built and installed"
echo "Installation directory: \"${ARM_INST}\""
echo "Build directory: \"${BUILD_PATH}\" (can be removed now)"
