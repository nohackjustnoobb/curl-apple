#!/bin/bash
set -e

usage() {
    echo "Usage: $0 <curl version> [curl configure options...]"
}

if [ "$1" = "--help" ]; then
    usage
    exit 0
fi
if [ -z "$1" ]; then
    usage >&2
    exit 1
fi

OPENSSL_VERSION="openssl-4.1.0"
LIBSSH2_VERSION="1.11.1"

VERSION=$1
shift
WITH_LIBSSH2=1
BUILD_ARGS=(--disable-shared --enable-static --without-libpsl --without-libidn2 --without-nghttp2)
for ARG in "$@"; do
    case "$ARG" in
        --without-libssh2) WITH_LIBSSH2=0 ;;
        *) BUILD_ARGS+=("$ARG") ;;
    esac
done

cd "$(dirname "$0")" || exit
ROOT="$(pwd -P)"

BUILDDIR="$ROOT/build"
JOBS=$(sysctl -n hw.logicalcpu_max)

rm -rf "$BUILDDIR"
mkdir -p "$BUILDDIR"
cd "$BUILDDIR" || exit

build_libssl() (
    SOURCE="$BUILDDIR/openssl"
    LOG="$BUILDDIR/libssl-$PLATFORM-$ARCH.log"

    if [ ! -d "$SOURCE" ]; then
        echo "- Check out OpenSSL $OPENSSL_VERSION"

        git clone --recursive --shallow-submodules --depth 1 --branch "$OPENSSL_VERSION" https://github.com/openssl/openssl.git >> "$LOG" 2>&1
    fi

    echo "- Build OpenSSL for $ARCH ($PLATFORM)"

    cd "$SOURCE" || exit

    if [ -f Makefile ]; then
        make distclean >> "$LOG" 2>&1
    fi

    BITCODE="-fembed-bitcode"
    if [ "$PLATFORM" = "maccatalyst" ]; then
        CONFIG="darwin64-$ARCH-cc"
        PLATFORM_FLAGS="no-asm enable-ec_nistp_64_gcc_128"
        BITCODE=""
    elif [ "$SDK" = "iphoneos" ]; then
        if [ "$ARCH" = "arm64" ]; then
            PLATFORM_FLAGS="no-async zlib-dynamic enable-ec_nistp_64_gcc_128"
            CONFIG="ios64-xcrun"
        elif [ "$ARCH" = "armv7" ]; then
            PLATFORM_FLAGS="no-async zlib-dynamic"
            CONFIG="ios-xcrun"
        else
            echo "OpenSSL configuration error: $ARCH on $SDK not supported!"
        fi
    elif [ "$SDK" = "iphonesimulator" ]; then
        if [ "$ARCH" = "arm64" ]; then
            PLATFORM_FLAGS="no-async zlib-dynamic enable-ec_nistp_64_gcc_128"
            CONFIG="iossimulator-xcrun"
        elif [ "$ARCH" = "i386" ]; then
            PLATFORM_FLAGS="no-asm"
            CONFIG="iossimulator-xcrun"
        elif [ "$ARCH" = "x86_64" ]; then
            PLATFORM_FLAGS="no-asm enable-ec_nistp_64_gcc_128"
            CONFIG="iossimulator-xcrun"
        else
            echo "OpenSSL configuration error: $ARCH on $SDK not supported!"
        fi
    elif [ "$SDK" = "macosx" ]; then
        if [ "$ARCH" = "i386" ]; then
            PLATFORM_FLAGS="no-asm"
            CONFIG="darwin-i386-cc"
        elif [ "$ARCH" = "x86_64" ]; then
            PLATFORM_FLAGS="no-asm enable-ec_nistp_64_gcc_128"
            CONFIG="darwin64-x86_64-cc"
        elif [ "$ARCH" = "arm64" ]; then
            PLATFORM_FLAGS="no-asm enable-ec_nistp_64_gcc_128"
            CONFIG="darwin64-arm64-cc"
        else
            echo "OpenSSL configuration error: $ARCH on $SDK not supported!"
        fi
    fi

    if [ -z "$CONFIG" ]; then
        return 1
    fi

    ./Configure \
        no-shared \
        $PLATFORM_FLAGS \
        --prefix="$SSL_PREFIX" \
        "$CONFIG" \
        CC="$TARGET_CC $BITCODE" \
        >> "$LOG" 2>&1

    make depend >> "$LOG" 2>&1
    make "-j$JOBS" build_libs >> "$LOG" 2>&1
    make install_dev >> "$LOG" 2>&1
)

build_libssh2() (
    SOURCE="$BUILDDIR/libssh2"
    LOG="$BUILDDIR/libssh2-$PLATFORM-$ARCH.log"

    if [ ! -d "$SOURCE" ]; then
        echo "- Download libssh2 $LIBSSH2_VERSION"
        ARCHIVE="$BUILDDIR/libssh2-$LIBSSH2_VERSION.tar.gz"
        curl -fsSL "https://libssh2.org/download/libssh2-$LIBSSH2_VERSION.tar.gz" -o "$ARCHIVE"
        mkdir -p "$SOURCE"
        tar -xzf "$ARCHIVE" -C "$SOURCE" --strip-components 1
    fi

    echo "- Build libssh2 for $ARCH ($PLATFORM)"
    BUILD_PATH="$BUILDDIR/$PLATFORM/build-libssh2-$ARCH"
    mkdir -p "$BUILD_PATH"
    cd "$BUILD_PATH" || exit

    "$SOURCE/configure" \
        --host="$HOST" \
        --disable-shared --enable-static \
        --with-crypto=openssl --with-libssl-prefix="$SSL_PREFIX" \
        --prefix="$SSH_PREFIX" \
        CC="$TARGET_CC" \
        CFLAGS="-Os" \
        >> "$LOG" 2>&1

    make "-j$JOBS" >> "$LOG" 2>&1
    make install >> "$LOG" 2>&1
)

build_libcurl() (
    SOURCE="$BUILDDIR/libcurl"
    LOG="$BUILDDIR/libcurl-$PLATFORM-$ARCH.log"

    ARCHIVE="$BUILDDIR/curl-$VERSION.tar.gz"
    if [ ! -f "$ARCHIVE" ]; then
        echo "- Download libcurl $VERSION"
        curl -fsSL "https://curl.se/download/curl-$VERSION.tar.gz" -o "$ARCHIVE"
    fi

    if [ -n "$GPG_VERIFY" ]; then
        echo "- Verify signature for curl-$VERSION.tar.gz"
        rm -f "$ARCHIVE.asc"
        curl -fsSL "https://curl.se/download/curl-$VERSION.tar.gz.asc" -o "$ARCHIVE.asc"
        gpg --verify "$ARCHIVE.asc" "$ARCHIVE" >/dev/null || exit
    fi

    # https://curl.se/docs/caextract.html
    CERTS="$BUILDDIR/cacert.pem"
    if [ ! -f "$CERTS" ]; then
        echo "- Download cacert file"
        curl -fsSL "https://curl.se/ca/cacert.pem" -o "$CERTS"
    fi

    echo "- Build libcurl for $ARCH ($PLATFORM)"

    # curl build writes compiled files into source dir, so clean up, by removing and unpacking again.
    rm -rf "$SOURCE"
    mkdir -p "$SOURCE"

    tar -xzf "$ARCHIVE" -C "$SOURCE" --strip-components 1

    cd "$SOURCE" || exit

    while IFS= read -r -d '' FILE; do
        patch -p1 < "$FILE"
    done < <(find "$ROOT/patches" -name '*.patch' -print0)

    CURL_PREFIX="$BUILDDIR/$PLATFORM/libcurl-$ARCH"
    SSH_ARG=--without-libssh2
    if [ "$WITH_LIBSSH2" = 1 ]; then
        SSH_ARG="--with-libssh2=$SSH_PREFIX"
    fi

    ./configure \
        --host="$HOST" \
        --with-openssl="$SSL_PREFIX" \
        "${BUILD_ARGS[@]}" \
        "$SSH_ARG" \
        --prefix "$CURL_PREFIX" \
        CC="$TARGET_CC" \
        CFLAGS="-pipe -Os -gdwarf-2" \
        >> "$LOG" 2>&1

    make "-j$JOBS" >> "$LOG" 2>&1
    make install >> "$LOG" 2>&1

    if [ "$WITH_LIBSSH2" = 1 ] && ! "$CURL_PREFIX/bin/curl-config" --protocols | grep -qx SFTP; then
        echo "libcurl was built without SFTP for $ARCH ($PLATFORM). See $LOG." >&2
        return 1
    fi
)

build_slice() (
    PLATFORM=$1
    ARCH=$2
    MIN=$3
    SDK=$PLATFORM

    if [ "$PLATFORM" = "maccatalyst" ]; then
        SDK="macosx"
        TARGET_FLAGS="-target $ARCH-apple-ios$MIN-macabi"
    else
        TARGET_FLAGS="-arch $ARCH -m$SDK-version-min=$MIN"
    fi

    SDKDIR=$(xcrun --sdk "$SDK" --show-sdk-path)
    CLANG=$(xcrun --sdk "$SDK" --find clang)
    # Configure also invokes the preprocessor without CFLAGS.
    TARGET_CC="$CLANG $TARGET_FLAGS -isysroot $SDKDIR"

    HOST="$ARCH-apple-darwin"
    if [ "$ARCH" = "arm64" ]; then
        HOST="arm-apple-darwin"
    fi

    SSL_PREFIX="$BUILDDIR/$PLATFORM/libssl-$ARCH"
    SSH_PREFIX="$BUILDDIR/$PLATFORM/libssh2-$ARCH"

    build_libssl
    if [ "$WITH_LIBSSH2" = 1 ]; then
        build_libssh2
    fi
    build_libcurl
)

fatten() {
    SDK=$1
    NAME=$2
    LIB=${3:-$NAME}

    echo "- Fatten $LIB in $NAME ($SDK)"

    mkdir -p "$BUILDDIR/$SDK/$NAME/lib"

    lipo \
        -arch arm64 "$BUILDDIR/$SDK/$NAME-arm64/lib/$LIB.a" \
        -arch x86_64 "$BUILDDIR/$SDK/$NAME-x86_64/lib/$LIB.a" \
        -create -output "$BUILDDIR/$SDK/$NAME/lib/$LIB.a"
}

create_framework() {
    SDK=$1
    IS_FAT=$2

    mkdir -p "$BUILDDIR/$SDK/curl.framework/Headers"
    mkdir -p "$BUILDDIR/$SDK/curl.framework/Resources"

    if [ -z "$IS_FAT" ]; then
        echo "- Create framework for $SDK"

        POSTFIX="-arm64"
    else
        echo "- Create framework for fat $SDK"

        POSTFIX=""
      fi

    LIBS=("$BUILDDIR/$SDK/libssl$POSTFIX/lib/libssl.a" \
        "$BUILDDIR/$SDK/libssl$POSTFIX/lib/libcrypto.a" \
        "$BUILDDIR/$SDK/libcurl$POSTFIX/lib/libcurl.a")

    if [ "$WITH_LIBSSH2" = 1 ]; then
        LIBS+=("$BUILDDIR/$SDK/libssh2$POSTFIX/lib/libssh2.a")
    fi

    libtool -no_warning_for_no_symbols -static -o "$BUILDDIR/$SDK/curl.framework/curl" "${LIBS[@]}"

    HEADERS=("$BUILDDIR/$SDK/libssl-arm64/include"/* \
        "$BUILDDIR/$SDK/libcurl-arm64/include/curl"/*)

    cp -r "${HEADERS[@]}" "$BUILDDIR/$SDK/curl.framework/Headers"

    cp "$BUILDDIR/cacert.pem" "$BUILDDIR/$SDK/curl.framework/Resources"
    if [ "$WITH_LIBSSH2" = 1 ]; then
        cp "$BUILDDIR/libssh2/COPYING" "$BUILDDIR/$SDK/curl.framework/Resources/libssh2-LICENSE.txt"
    fi

    SUPPORTED_PLATFORM=$SDK
    if [ "$SDK" = "maccatalyst" ]; then
        SUPPORTED_PLATFORM="MacOSX"
    fi

# https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html#//apple_ref/doc/uid/20001431-102088
    cat > "$BUILDDIR/$SDK/curl.framework/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>curl</string>
  <key>CFBundleIdentifier</key>
  <string>org.greatfire.curl</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>curl</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleShortVersionString</key>
  <string>${VERSION}</string>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>${SUPPORTED_PLATFORM}</string>
  </array>
  <key>CFBundleVersion</key>
  <string>${VERSION}</string>
</dict>
</plist>
EOF
}


build_platform() {
    local PLATFORM=$1 MIN=$2

    build_slice "$PLATFORM" arm64 "$MIN"
    if [ "$3" = "fat" ]; then
        build_slice "$PLATFORM" x86_64 "$MIN"
        fatten "$PLATFORM" libssl
        fatten "$PLATFORM" libssl libcrypto
        fatten "$PLATFORM" libcurl
        if [ "$WITH_LIBSSH2" = 1 ]; then
            fatten "$PLATFORM" libssh2
        fi
    fi
    create_framework "$PLATFORM" "$3"
    FRAMEWORKS+=(-framework "$BUILDDIR/$PLATFORM/curl.framework")
}

FRAMEWORKS=()
build_platform iphoneos        12.0
build_platform iphonesimulator 12.0 fat
build_platform macosx          10.13 fat
build_platform maccatalyst     14.0 fat

rm -rf "$ROOT/curl.xcframework"
xcodebuild -create-xcframework "${FRAMEWORKS[@]}" -output "$ROOT/curl.xcframework"

plutil -insert CFBundleVersion -string "$VERSION" "$ROOT/curl.xcframework/Info.plist"
