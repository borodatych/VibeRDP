/// A self-signed server certificate for vibe.test, like the one Windows makes for RDP; its private key was discarded
/// A year of validity keeps it within the macOS limit for server certificates, and for an untrusted chain
/// macOS names the missing trust first whatever the date, so the tests outlive the validity
/// Reference fingerprint from an independent tool: openssl x509 -noout -fingerprint -sha256
enum Fixtures {
    static let certificatePEM = """
        -----BEGIN CERTIFICATE-----
        MIIC2DCCAcCgAwIBAgIJAN7Z341/han9MA0GCSqGSIb3DQEBCwUAMBQxEjAQBgNV
        BAMMCXZpYmUudGVzdDAeFw0yNjA5MjQxNjE2NTRaFw0yNzA5MjQxNjE2NTRaMBQx
        EjAQBgNVBAMMCXZpYmUudGVzdDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoC
        ggEBANef9iVkYfzgTFNDfC6AuyZseQgJaEbeL5ALpaYis25nEFmyp7SwS16aBG5B
        w657DNNBwfC5i3ggcEbT9RCx4NQzZ9wv/xOomvBrIPZujFhK7H26sJWGsexcWf2w
        cNgdatbkP8GpJX1Oznb5my4zFuXeCj2kejCLGLtNT7clrVB9ZF7AwiUfaMMkflMw
        +rVZ6lYYUWEPMiSYBoU+6SdMJ+OfDV9DH1gcBYZ4no+aFlqFh939g1sqRAVEoYZl
        l369RKZ416oEY95wOk/uzmuk/Xno+bxkgqBmzgnIvL9PM70u1IF5A/Y47KK1YeZM
        n4QZa4PCwyr9ilmRNdBN6Uqv2NkCAwEAAaMtMCswFAYDVR0RBA0wC4IJdmliZS50
        ZXN0MBMGA1UdJQQMMAoGCCsGAQUFBwMBMA0GCSqGSIb3DQEBCwUAA4IBAQB95lUo
        Y2rCtA60CgqEl4O7YYEuAR7l154kGqNyKkJHebgBivXBe3DpKPlmgdTZu1nKNctj
        iPJQyU7UANGuoyisGN/lSzKmRoQv9Z5PERTTMHo7eta6k7WOvcUXrd8aqTkj3TbF
        Ldr3JA+ta42sfHlOlQKCqEK0VOeyPU5U1i2znUJk+zMCCIjrJrUtn6KZrRhFtdS7
        J/VRvUbAhVBjRDPkFQ3/fglpziC0T4x05P1vihqCWMuA9hkcrnkSoywR6PNk6gAp
        EazyKv5k2tftNs8KCFUDV7ITj7khkQPWsW+ltvOPspEF+ShayEkVWoD8sX2gl069
        WTaGOTcFrhaQmHjX
        -----END CERTIFICATE-----
        """

    static let certificateFingerprint =
        "F9:AA:8E:7C:99:6F:23:0B:93:E0:D6:74:12:DB:C2:D7:1C:97:A1:AC:E7:31:29:51:B9:AC:5C:B4:3B:4E:CE:67"
}
