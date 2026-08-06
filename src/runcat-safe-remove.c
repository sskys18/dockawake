#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <libgen.h>
#include <limits.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static void usage(void) {
    fprintf(stderr, "usage: runcat-safe-remove --root ROOT --candidate PATH --expected-device DEV --expected-inode INO --quarantine PATH --bundle-id ID --team-id TEAM\n");
}

static bool approved_root(const char *root) {
    if (strcmp(root, "/Applications") == 0) return true;
    const char *home = getenv("HOME");
    if (home == NULL) return false;
    char expected[PATH_MAX];
    if (snprintf(expected, sizeof(expected), "%s/Applications", home) >= (int)sizeof(expected)) return false;
    char canonical[PATH_MAX];
    return realpath(expected, canonical) != NULL && strcmp(root, canonical) == 0;
}

/* Splits PATH into its parent directory and final component, rejecting anything
   that is not a plain direct child name. */
static bool split_child(const char *path, const char *root, char *name, size_t nameSize) {
    char copy[PATH_MAX];
    if (strlen(path) >= sizeof(copy)) return false;
    strcpy(copy, path);
    char *parent = dirname(copy);
    char canonicalParent[PATH_MAX];
    if (realpath(parent, canonicalParent) == NULL) return false;
    if (strcmp(canonicalParent, root) != 0) return false;

    char nameCopy[PATH_MAX];
    strcpy(nameCopy, path);
    char *base = basename(nameCopy);
    if (base[0] == '\0' || strcmp(base, ".") == 0 || strcmp(base, "..") == 0) return false;
    if (strchr(base, '/') != NULL) return false;
    if (strlen(base) >= nameSize) return false;
    strcpy(name, base);
    return true;
}

/* Reads the complete tagged value for KEY out of `codesign -d` output, requiring
   the whole line to match so a prefix cannot spoof the identity. */
static bool field_equals(const char *output, const char *key, const char *expected) {
    size_t keyLength = strlen(key);
    const char *cursor = output;
    while (cursor != NULL && *cursor != '\0') {
        const char *lineEnd = strchr(cursor, '\n');
        size_t lineLength = lineEnd == NULL ? strlen(cursor) : (size_t)(lineEnd - cursor);
        if (lineLength > keyLength && strncmp(cursor, key, keyLength) == 0) {
            size_t valueLength = lineLength - keyLength;
            return valueLength == strlen(expected) && strncmp(cursor + keyLength, expected, valueLength) == 0;
        }
        cursor = lineEnd == NULL ? NULL : lineEnd + 1;
    }
    return false;
}

static int run_tool(char *const argv[], int captureFileno, char *output, size_t outputSize) {
    int pipefd[2];
    if (pipe(pipefd) != 0) return -1;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], captureFileno);
    posix_spawn_file_actions_addclose(&actions, pipefd[0]);
    pid_t pid;
    int status = posix_spawn(&pid, argv[0], &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(pipefd[1]);
    ssize_t total = 0, bytes;
    while (total < (ssize_t)outputSize - 1 && (bytes = read(pipefd[0], output + total, outputSize - 1 - (size_t)total)) > 0) {
        total += bytes;
    }
    close(pipefd[0]);
    output[total] = '\0';
    if (status != 0 || waitpid(pid, &status, 0) != pid || !WIFEXITED(status) || WEXITSTATUS(status) != 0) return -1;
    return 0;
}

static int verify_signature(const char *path, const char *bundleID, const char *teamID) {
    char requirement[PATH_MAX];
    if (snprintf(requirement, sizeof(requirement),
                 "identifier \"%s\" and anchor apple generic and certificate leaf[subject.OU] = \"%s\"",
                 bundleID, teamID) >= (int)sizeof(requirement)) {
        return -1;
    }
    char ignored[1024];
    char *verifyArgs[] = { "/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", requirement, (char *)path, NULL };
    if (run_tool(verifyArgs, STDERR_FILENO, ignored, sizeof(ignored)) != 0) return -1;

    char output[8192];
    char *displayArgs[] = { "/usr/bin/codesign", "-d", "--verbose=4", (char *)path, NULL };
    if (run_tool(displayArgs, STDERR_FILENO, output, sizeof(output)) != 0) return -1;
    if (!field_equals(output, "Identifier=", bundleID)) return -1;
    if (!field_equals(output, "TeamIdentifier=", teamID)) return -1;
    return 0;
}

static int bundle_matches(const char *path, const char *bundleID) {
    char plist[PATH_MAX];
    if (snprintf(plist, sizeof(plist), "%s/Contents/Info.plist", path) >= (int)sizeof(plist)) return -1;
    char output[PATH_MAX];
    char *args[] = { "/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", plist, NULL };
    if (run_tool(args, STDOUT_FILENO, output, sizeof(output)) != 0) return -1;
    size_t length = strlen(output);
    while (length > 0 && (output[length - 1] == '\n' || output[length - 1] == '\r')) output[--length] = '\0';
    return strcmp(output, bundleID) == 0 ? 0 : -1;
}

static int contains_symlink(const char *path) {
    char *paths[] = { (char *)path, NULL };
    FTS *tree = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (tree == NULL) return 1;
    FTSENT *entry;
    int forbidden = 0;
    errno = 0;
    while ((entry = fts_read(tree)) != NULL) {
        if (entry->fts_info == FTS_SL || entry->fts_info == FTS_SLNONE || entry->fts_info == FTS_ERR || entry->fts_info == FTS_DNR || entry->fts_info == FTS_NS) {
            forbidden = 1;
            break;
        }
    }
    if (errno != 0) forbidden = 1;
    if (fts_close(tree) != 0) forbidden = 1;
    return forbidden;
}

static int delete_tree(const char *path) {
    char *paths[] = { (char *)path, NULL };
    FTS *tree = fts_open(paths, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (tree == NULL) return -1;
    FTSENT *entry;
    int failed = 0;
    errno = 0;
    while ((entry = fts_read(tree)) != NULL) {
        switch (entry->fts_info) {
            case FTS_DP:
                if (rmdir(entry->fts_accpath) != 0) failed = 1;
                break;
            case FTS_F:
                if (unlink(entry->fts_accpath) != 0) failed = 1;
                break;
            case FTS_D:
                break;
            default:
                failed = 1;
                break;
        }
    }
    if (errno != 0) failed = 1;
    if (fts_close(tree) != 0) failed = 1;
    return failed ? -1 : 0;
}

/* Confirms NAME inside DIRFD is still the exact directory object bound to
   DEVICE/INODE and is not a symlink. */
static bool object_is_bound(int dirfd, const char *name, unsigned long long device, unsigned long long inode) {
    struct stat info;
    if (fstatat(dirfd, name, &info, AT_SYMLINK_NOFOLLOW) != 0) return false;
    if (!S_ISDIR(info.st_mode)) return false;
    return (unsigned long long)info.st_dev == device && (unsigned long long)info.st_ino == inode;
}

int main(int argc, char **argv) {
    const char *root = NULL, *candidate = NULL, *quarantine = NULL, *bundleID = NULL, *teamID = NULL;
    unsigned long long expectedDevice = 0, expectedInode = 0;
    for (int i = 1; i < argc; i += 2) {
        if (i + 1 >= argc) { usage(); return 64; }
        if (strcmp(argv[i], "--root") == 0) root = argv[i + 1];
        else if (strcmp(argv[i], "--candidate") == 0) candidate = argv[i + 1];
        else if (strcmp(argv[i], "--expected-device") == 0) expectedDevice = strtoull(argv[i + 1], NULL, 10);
        else if (strcmp(argv[i], "--expected-inode") == 0) expectedInode = strtoull(argv[i + 1], NULL, 10);
        else if (strcmp(argv[i], "--quarantine") == 0) quarantine = argv[i + 1];
        else if (strcmp(argv[i], "--bundle-id") == 0) bundleID = argv[i + 1];
        else if (strcmp(argv[i], "--team-id") == 0) teamID = argv[i + 1];
        else { usage(); return 64; }
    }
    if (!root || !candidate || !quarantine || !bundleID || !teamID || expectedDevice == 0 || expectedInode == 0) { usage(); return 64; }

    char canonicalRoot[PATH_MAX];
    if (!realpath(root, canonicalRoot) || !approved_root(canonicalRoot)) {
        fprintf(stderr, "runcat-safe-remove: path outside authorized boundary\n"); return 65;
    }

    char candidateName[NAME_MAX + 1], quarantineName[NAME_MAX + 1];
    if (!split_child(candidate, canonicalRoot, candidateName, sizeof(candidateName)) ||
        !split_child(quarantine, canonicalRoot, quarantineName, sizeof(quarantineName)) ||
        strcmp(candidateName, quarantineName) == 0) {
        fprintf(stderr, "runcat-safe-remove: path outside authorized boundary\n"); return 65;
    }

    int dirfd = open(canonicalRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dirfd < 0) { perror("runcat-safe-remove: open root"); return 65; }

    struct stat quarantineStat;
    if (!object_is_bound(dirfd, candidateName, expectedDevice, expectedInode) ||
        fstatat(dirfd, quarantineName, &quarantineStat, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT) {
        fprintf(stderr, "runcat-safe-remove: object or quarantine precondition failed\n");
        close(dirfd);
        return 66;
    }

    if (renameat(dirfd, candidateName, dirfd, quarantineName) != 0) {
        perror("runcat-safe-remove: quarantine rename");
        close(dirfd);
        return 68;
    }

    bool valid = object_is_bound(dirfd, quarantineName, expectedDevice, expectedInode) &&
                 fstatat(dirfd, candidateName, &quarantineStat, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT &&
                 bundle_matches(quarantine, bundleID) == 0 &&
                 verify_signature(quarantine, bundleID, teamID) == 0 &&
                 !contains_symlink(quarantine) &&
                 object_is_bound(dirfd, quarantineName, expectedDevice, expectedInode);
    if (!valid) {
        if (fstatat(dirfd, candidateName, &quarantineStat, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT &&
            object_is_bound(dirfd, quarantineName, expectedDevice, expectedInode) &&
            renameat(dirfd, quarantineName, dirfd, candidateName) == 0) {
            fprintf(stderr, "runcat-safe-remove: validation mismatch, bundle restored at %s\n", candidate);
            close(dirfd);
            return 69;
        }
        fprintf(stderr, "runcat-safe-remove: validation mismatch, quarantine retained at %s\n", quarantine);
        close(dirfd);
        return 70;
    }

    if (delete_tree(quarantine) != 0) {
        fprintf(stderr, "runcat-safe-remove: deletion failed, quarantine retained at %s\n", quarantine);
        close(dirfd);
        return 71;
    }
    close(dirfd);
    printf("removed %s\n", candidate);
    return 0;
}
