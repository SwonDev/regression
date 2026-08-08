#include <errno.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

static const char *const child_environment_key = "REGRESSION_FLI_4K_CHILD";

static void print_boolean(bool value)
{
    fputs(value ? "true" : "false", stdout);
}

int main(int argc, char **argv)
{
#if !defined(__APPLE__) || !defined(__aarch64__)
#error "This probe must be built for macOS arm64."
#endif

    const long page_size = sysconf(_SC_PAGESIZE);
    const bool child = getenv(child_environment_key) != NULL;

    if (child)
    {
        fputs("{\"schema\":1,\"probe\":\"wine-4k-spawn\",\"phase\":\"child\",", stdout);
        fprintf(stdout, "\"page_size\":%ld,\"page_size_is_4k\":", page_size);
        print_boolean(page_size == 4096);
        fputs(",\"wine_executed\":false,\"fex_executed\":false,"
              "\"proton_executed\":false,\"steam_executed\":false,"
              "\"game_executed\":false,\"eac_executed\":false}\n", stdout);
        return page_size == 4096 ? 0 : 72;
    }

    if (argc < 1 || argv == NULL || argv[0] == NULL || page_size <= 0)
        return 70;

    posix_spawnattr_t attributes;
    int result = posix_spawnattr_init(&attributes);
    if (result == 0)
        result = posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETEXEC);
    if (result == 0)
        result = posix_spawnattr_set_4k_page_size_np(&attributes);
    if (result != 0)
    {
        fprintf(stderr,
                "{\"schema\":1,\"probe\":\"wine-4k-spawn\","
                "\"phase\":\"attribute-setup\",\"page_size\":%ld,"
                "\"result\":%d,\"error\":\"%s\"}\n",
                page_size, result, strerror(result));
        return 71;
    }

    if (setenv(child_environment_key, "1", 1) != 0)
    {
        const int saved_errno = errno;
        posix_spawnattr_destroy(&attributes);
        fprintf(stderr,
                "{\"schema\":1,\"probe\":\"wine-4k-spawn\","
                "\"phase\":\"environment-setup\",\"page_size\":%ld,"
                "\"result\":%d,\"error\":\"%s\"}\n",
                page_size, saved_errno, strerror(saved_errno));
        return 73;
    }

    fprintf(stderr,
            "{\"schema\":1,\"probe\":\"wine-4k-spawn\","
            "\"phase\":\"before-setexec\",\"page_size\":%ld,"
            "\"requested_page_size\":4096,\"setexec\":true,"
            "\"wine_executed\":false,\"fex_executed\":false,"
            "\"proton_executed\":false,\"steam_executed\":false,"
            "\"game_executed\":false,\"eac_executed\":false}\n",
            page_size);
    fflush(NULL);

    result = posix_spawn(NULL, argv[0], NULL, &attributes, argv, environ);
    posix_spawnattr_destroy(&attributes);

    fprintf(stderr,
            "{\"schema\":1,\"probe\":\"wine-4k-spawn\","
            "\"phase\":\"setexec-returned\",\"page_size\":%ld,"
            "\"result\":%d,\"error\":\"%s\"}\n",
            page_size, result, strerror(result));
    return result == 0 ? 74 : 75;
}
