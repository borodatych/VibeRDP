/*
 * Smoke test of the universal static FreeRDP build: it must link, run and contain exactly the expected channels
 * Usage: link-check <runtime prefix> <built-in channel>... -- <disabled channel>...
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <freerdp/addin.h>
#include <freerdp/client/channels.h>
#include <freerdp/freerdp.h>
#include <openssl/crypto.h>

static int failures = 0;

static void expectUnderPrefix(const char* what, const char* value, const char* prefix)
{
    const size_t length = strlen(prefix);
    const char* start = value ? strchr(value, '/') : NULL;

    printf("%s: %s\n", what, value ? value : "(null)");
    /* Every runtime lookup must stay under the root-only prefix, never under a build-machine path */
    if (!start || strncmp(start, prefix, length) != 0 || start[length] != '/')
    {
        fprintf(stderr, "FAIL %s is outside %s\n", what, prefix);
        failures++;
    }
}

int main(int argc, char* argv[])
{
    if (argc < 2)
    {
        fprintf(stderr, "usage: %s <runtime prefix> <channel>... -- <channel>...\n", argv[0]);
        return 2;
    }
    const char* prefix = argv[1];

    freerdp* instance = freerdp_new();
    if (!instance)
    {
        fprintf(stderr, "FAIL freerdp_new\n");
        return 1;
    }
    freerdp_free(instance);

    printf("FreeRDP %s, %s\n", freerdp_get_version_string(), OpenSSL_version(OPENSSL_VERSION));

    char* addinPath = freerdp_get_dynamic_addin_install_path();
    expectUnderPrefix("FreeRDP plugins", addinPath, prefix);
    free(addinPath);
    expectUnderPrefix("OpenSSL config and CA store", OpenSSL_version(OPENSSL_DIR), prefix);
    expectUnderPrefix("OpenSSL modules", OpenSSL_version(OPENSSL_MODULES_DIR), prefix);

    int expectBuiltIn = 1;
    for (int i = 2; i < argc; i++)
    {
        if (strcmp(argv[i], "--") == 0)
        {
            expectBuiltIn = 0;
            continue;
        }
        const int builtIn = freerdp_channels_load_static_addin_entry(argv[i], NULL, NULL, 0) != NULL;
        if (builtIn != expectBuiltIn)
        {
            fprintf(stderr, "FAIL channel %s must be %s\n", argv[i], expectBuiltIn ? "built in" : "absent");
            failures++;
        }
    }

    printf("%s\n", failures ? "FAIL" : "OK");
    return failures ? 1 : 0;
}
