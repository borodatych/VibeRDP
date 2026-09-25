/*
 * The Kerberos ticket cache of a session: in memory, of this session alone, and destroyed with it
 * The engine gets the tickets with the password of the connection, and the caches of the user stay untouched
 */

#ifndef VRC_KERBEROS_H
#define VRC_KERBEROS_H

#include <stdbool.h>
#include <stddef.h>

/* Room for MEMORY:VibeRDP. and the widest 64-bit number */
#define VRC_KERBEROS_CACHE_NAME_SIZE 48u

/* A cache name that no other session of the process gets; false when the buffer is too small */
bool vrcKerberosCacheName(char* buffer, size_t size);

/* Destroys the cache with its tickets; for a name without a cache nothing happens */
void vrcKerberosCacheDestroy(const char* name);

#endif
