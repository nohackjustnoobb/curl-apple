# curl-apple

Pre-compiled libcurl framework for iOS and macOS applications! Automatically updated within 24-hours of a new release of curl.

Let me know if you need tvOS and/or watchOS too.
This project is prepared to provide these, but there's no point to waste space and time if nobody needs it.

If you want something more convenient to use curl in your projects, you might want to have a look at
https://github.com/greatfire/SwiftyCurl.

## Using the pre-compiled framework

1. Download and extract curl.xcframework.zip from the latest release
2. Compare the SHA-256 checksum of the downloaded framework with the fingerprint in the release
   ```bash
   shasum -a 256 curl.xcframework.zip
   ```
3. Select your target in Xcode and click the "+" under Frameworks, Libraries, and Embedded Content  
   ![Screenshot of the Frameworks, Libraries, and Embedded Content section in Xcode with the plus button circled](resources/frameworks.png)
4. Click "Add Other" then "Add Files..."  
   ![Screenshot of a dropdown menu with the add files option highlighted](resources/addfiles.png)
5. Select the extracted curl.xcframework directory

## Compile it yourself

Use the included build script to compile a specific version or customize the configuration options

```
./build-apple.sh <curl version> [optional configure parameters]
```

The build script always passes `--disable-shared`, `--enable-static`, `--with-openssl`, `--without-libpsl`, `--without-libidn2`, and `--without-nghttp2`.
It also passes `--with-apple-sectrust` by default for native certificate verification in curl 8.17.0 and later. Pass `--without-apple-sectrust` to opt out.

## TLS support

The framework uses OpenSSL for TLS, including TLS 1.3. With Apple SecTrust enabled, link `Security.framework` and `CoreFoundation.framework` in your app target.
See [curl's certificate verification guide](https://curl.se/docs/sslcerts.html#apple--opensslgnutls).

Builds without SecTrust include `cacert.pem`. With SecTrust enabled, libcurl uses the system trust store by default.
For a private CA, you can install it as trusted on the device or pass its PEM file to `CURLOPT_CAINFO`.
To use the system store alongside a custom CA file, include `CURLSSLOPT_NATIVE_CA` in `CURLOPT_SSL_OPTIONS`.

Using a client identity directly from the Keychain for mutual TLS requires separate integration.

## Authors

This project was originally devised by Ian Spence:
https://github.com/tls-inspector/curl-ios/

MacOS extensions and minor improvements by Benjamin Erhart.
