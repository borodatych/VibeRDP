/*
 * Kerberos tests: the ticket cache of a session, built from core/src/kerberos.c directly
 * Usage: kerberosTests <test name>; CTest registers every test separately
 */

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include <krb5/krb5.h>

#include "kerberos.h"

#define CHECK(condition)                                                                        \
    do                                                                                          \
    {                                                                                           \
        if (!(condition))                                                                       \
        {                                                                                       \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #condition);       \
            return false;                                                                       \
        }                                                                                       \
    } while (0)

#define CACHE_PREFIX "MEMORY:VibeRDP."

/* Every call gives a name of its own in the memory cache type; a buffer too small for it fails */
static bool testNamesAreUnique(void)
{
    char first[VRC_KERBEROS_CACHE_NAME_SIZE];
    char second[VRC_KERBEROS_CACHE_NAME_SIZE];
    char small[sizeof(CACHE_PREFIX)];

    CHECK(vrcKerberosCacheName(first, sizeof(first)));
    CHECK(vrcKerberosCacheName(second, sizeof(second)));
    CHECK(strncmp(first, CACHE_PREFIX, strlen(CACHE_PREFIX)) == 0);
    CHECK(strncmp(second, CACHE_PREFIX, strlen(CACHE_PREFIX)) == 0);
    CHECK(strcmp(first, second) != 0);
    CHECK(!vrcKerberosCacheName(small, sizeof(small)));
    return true;
}

/* The cache the engine filled is found by its name and destroyed with its principal */
static bool testDestroyTakesTheCache(void)
{
    char name[VRC_KERBEROS_CACHE_NAME_SIZE];
    krb5_context context = NULL;
    krb5_principal principal = NULL;
    krb5_principal left = NULL;
    krb5_ccache cache = NULL;

    CHECK(vrcKerberosCacheName(name, sizeof(name)));
    CHECK(krb5_init_context(&context) == 0);
    CHECK(krb5_parse_name(context, "tester@VIBERDP.TEST", &principal) == 0);
    CHECK(krb5_cc_resolve(context, name, &cache) == 0);
    CHECK(krb5_cc_initialize(context, cache, principal) == 0);
    CHECK(krb5_cc_close(context, cache) == 0);

    vrcKerberosCacheDestroy(name);

    CHECK(krb5_cc_resolve(context, name, &cache) == 0);
    CHECK(krb5_cc_get_principal(context, cache, &left) != 0);
    CHECK(krb5_cc_destroy(context, cache) == 0);
    krb5_free_principal(context, principal);
    krb5_free_context(context);
    return true;
}

/* A session that never connected has no name, and a name nobody used has no cache: neither is an error */
static bool testDestroyWithoutACache(void)
{
    char name[VRC_KERBEROS_CACHE_NAME_SIZE];

    CHECK(vrcKerberosCacheName(name, sizeof(name)));
    vrcKerberosCacheDestroy(NULL);
    vrcKerberosCacheDestroy(name);
    return true;
}

typedef struct TestCase {
    const char* name;
    bool (*run)(void);
} TestCase;

static const TestCase tests[] = {
    { "namesAreUnique", testNamesAreUnique },
    { "destroyTakesTheCache", testDestroyTakesTheCache },
    { "destroyWithoutACache", testDestroyWithoutACache },
};

int main(int argc, char* argv[])
{
    if (argc != 2)
    {
        fprintf(stderr, "usage: %s <test name>\n", argv[0]);
        return 2;
    }
    for (size_t i = 0; i < sizeof(tests) / sizeof(tests[0]); i++)
        if (strcmp(tests[i].name, argv[1]) == 0)
            return tests[i].run() ? 0 : 1;

    fprintf(stderr, "unknown test: %s\n", argv[1]);
    return 2;
}
