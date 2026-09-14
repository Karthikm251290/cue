#include <sqlite3.h>
#include <stdint.h>
#include <sys/types.h>
typedef struct { int pid; int parent; uint64_t started; uint64_t terminal; char name[256]; char tty[128]; } SCProcess;
int sc_process(int pid, SCProcess *result);
typedef void (*SCKeyCallback)(void *context, int key, int down);
void *sc_deck_open(SCKeyCallback callback, void *context, int *error);
int sc_deck_image(void *deck, int key, const unsigned char *bytes, int length);
int sc_deck_brightness(void *deck, int brightness);
int sc_deck_connected(void *deck);
void sc_deck_close(void *deck);
