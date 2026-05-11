#include <signal.h>
#include <unistd.h>

int main(void) {
  sigset_t s;
  sigfillset(&s);
  sigprocmask(SIG_BLOCK, &s, 0);
  for (;;) pause();
}
