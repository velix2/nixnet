// PID 1 for named jails: keeps the pid namespace alive across `jail enter`s. On
// SIGINT/SIGTERM it destroys the jail — forwards SIGTERM so processes run their
// cleanup traps, waits for the namespace to drain, then exits. Exiting PID 1
// tears the namespace down, so the kernel SIGKILLs anything still alive; a
// deadline bounds the wait so a stuck process can't hang teardown.
//
// SIGINT must be handled explicitly (PID 1 silently drops signals it has no
// handler for). We forward SIGTERM, not SIGINT: a non-interactive shell ignores
// SIGINT while waiting on a foreground command but runs its trap on SIGTERM.
//
// We poll /proc instead of wait(): a `jail enter` command is a child of an
// nsenter in the outer namespace (its PPid is 0 inside this namespace), not of
// init, so wait() would return ECHILD and miss it.
#include <signal.h>
#include <unistd.h>
#include <dirent.h>
#include <time.h>

// Number of processes in our pid namespace; init itself always counts as one.
static int procs_left(void) {
    DIR *d = opendir("/proc");
    if (!d) return -1;
    int n = 0;
    struct dirent *e;
    while ((e = readdir(d)))
        if (e->d_name[0] >= '1' && e->d_name[0] <= '9') n++;
    closedir(d);
    return n;
}

int main(void) {
    sigset_t s;
    sigfillset(&s);
    sigprocmask(SIG_BLOCK, &s, 0);

    sigset_t w;
    sigemptyset(&w);
    sigaddset(&w, SIGINT);
    sigaddset(&w, SIGTERM);
    int sig;
    sigwait(&w, &sig);

    kill(-1, SIGTERM);

    // Wait for everyone else to exit, polling every 20 ms up to a 5 s deadline.
    time_t start = time(NULL);
    struct timespec poll = { 0, 20 * 1000 * 1000 };  // 20 ms
    while (procs_left() > 1 && time(NULL) - start < 5)
        nanosleep(&poll, NULL);
    return 0;
}
