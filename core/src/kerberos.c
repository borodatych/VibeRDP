/*
 * The Kerberos ticket cache of a session
 * A MEMORY cache lives in the process under its name until it is destroyed, whatever context opened it,
 * so the one the engine filled is reached here by name
 */

#include "kerberos.h"

#include <inttypes.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>

#include <krb5/krb5.h>

static atomic_uint_fast64_t nextCacheNumber = 0;

bool vrcKerberosCacheName(char* buffer, size_t size)
{
    const uint_fast64_t number = atomic_fetch_add(&nextCacheNumber, 1);
    const int written = snprintf(buffer, size, "MEMORY:VibeRDP.%" PRIuFAST64, number);
    return written > 0 && (size_t)written < size;
}

void vrcKerberosCacheDestroy(const char* name)
{
    krb5_context context = NULL;
    krb5_ccache cache = NULL;

    if (!name || krb5_init_context(&context) != 0)
        return;
    /* Resolving a MEMORY name never fails for want of a cache: it makes an empty one, which goes too */
    if (krb5_cc_resolve(context, name, &cache) == 0)
        (void)krb5_cc_destroy(context, cache);
    krb5_free_context(context);
}
