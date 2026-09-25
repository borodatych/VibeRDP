/*
 * Temporary folders of files for the file tests of the clipboard
 */

#ifndef VRC_TESTS_FILE_TREES_H
#define VRC_TESTS_FILE_TREES_H

#include <stdbool.h>
#include <stddef.h>
#include <time.h>

/* Room for any path of the tests */
#define FILE_TREE_PATH 1024

/* A fresh empty folder in the temporary folder of the user; root gets its path */
bool fileTreeMake(char root[FILE_TREE_PATH]);
/* A file of this text at a path relative to root, with the folders on the way */
bool fileTreeWrite(const char* root, const char* name, const char* text);
bool fileTreeSetTime(const char* root, const char* name, time_t modified);
/* Whether the file holds exactly this text */
bool fileTreeHolds(const char* root, const char* name, const char* text);
/* Removes root and everything in it */
bool fileTreeRemove(const char* root);

#endif
