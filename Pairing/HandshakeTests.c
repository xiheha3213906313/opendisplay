#include "ODPairing.h"

#include <assert.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

typedef struct {
    pthread_mutex_t lock;
    pthread_cond_t available;
    char code[7];
} prompt;

typedef struct {
    int fd, sender, intent, result, fresh, attempts, wrong, known, allowed;
    const char *id;
    uint8_t exported[32], key[32];
    prompt *ui;
} peer;

static int read_bytes(void *context, uint8_t *buffer, size_t size) {
    peer *p = context;
    while (size) {
        ssize_t n = read(p->fd, buffer, size);
        if (n <= 0) return 0;
        buffer += n;
        size -= (size_t)n;
    }
    return 1;
}

static int write_bytes(void *context, const uint8_t *buffer, size_t size) {
    peer *p = context;
    while (size) {
        ssize_t n = write(p->fd, buffer, size);
        if (n <= 0) return 0;
        buffer += n;
        size -= (size_t)n;
    }
    return 1;
}

static int inspect_peer(void *context, const char *id, const char *name, int intent) {
    peer *p = context;
    return p->allowed && strlen(id) == 36 && strlen(name) == 4 && intent > 0;
}

static int load_peer(void *context, const char *id, uint8_t *key) {
    (void)id;
    peer *p = context;
    if (p->known) memcpy(key, p->key, 32);
    return p->known;
}

static int code_prompt(void *context, const char *name, char *code, int display) {
    (void)name;
    peer *p = context;
    p->attempts++;
    pthread_mutex_lock(&p->ui->lock);
    if (display) {
        memcpy(p->ui->code, code, 7);
        pthread_cond_signal(&p->ui->available);
    } else {
        while (!p->ui->code[0]) pthread_cond_wait(&p->ui->available, &p->ui->lock);
        memcpy(code, p->ui->code, 6);
        if (p->wrong) code[0] = code[0] == '9' ? '0' : (char)(code[0] + 1);
    }
    pthread_mutex_unlock(&p->ui->lock);
    return 1;
}

static void *run_peer(void *context) {
    peer *p = context;
    static const od_lan_io io = {read_bytes, write_bytes, inspect_peer, load_peer, code_prompt};
    od_lan_result result;
    p->result = od_lan_handshake(&io, p, p->sender, p->intent, p->id, "Peer", p->exported, &result);
    if (p->result == 1) {
        p->fresh = result.fresh;
        memcpy(p->key, result.secret, 32);
    }
    close(p->fd);
    return NULL;
}

static void run(peer *sender, peer *receiver) {
    int pair[2];
    assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
    prompt ui = { .lock = PTHREAD_MUTEX_INITIALIZER, .available = PTHREAD_COND_INITIALIZER };
    sender->fd = pair[0];
    receiver->fd = pair[1];
    sender->ui = receiver->ui = &ui;
    sender->attempts = receiver->attempts = 0;
    pthread_t thread;
    assert(pthread_create(&thread, NULL, run_peer, receiver) == 0);
    run_peer(sender);
    assert(pthread_join(thread, NULL) == 0);
    pthread_mutex_destroy(&ui.lock);
    pthread_cond_destroy(&ui.available);
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    alarm(15);
    peer sender = { .sender = 1, .intent = 1, .allowed = 1,
                    .id = "00000000-0000-0000-0000-000000000001" };
    peer receiver = { .allowed = 1, .id = "00000000-0000-0000-0000-000000000002" };
    run(&sender, &receiver);
    assert(sender.result == 1 && receiver.result == 1 && sender.fresh && receiver.fresh);
    assert(od_pair_equal(sender.key, receiver.key));
    sender.known = receiver.known = 1;
    sender.intent = 0;
    receiver.intent = 2;
    sender.exported[0] = receiver.exported[0] = 199;
    run(&sender, &receiver);
    assert(sender.result == 1 && receiver.result == 1 && !sender.fresh && !receiver.fresh);
    assert(sender.attempts == 0 && receiver.attempts == 0);
    sender.exported[0] = 200;
    run(&sender, &receiver);
    assert(sender.result != 1 && receiver.result != 1);
    sender.known = 0;
    run(&sender, &receiver);
    assert(sender.result == -2 && receiver.result == -2);
    receiver.known = 0;
    receiver.intent = 1;
    sender.exported[0] = receiver.exported[0];
    sender.wrong = 1;
    run(&sender, &receiver);
    assert(sender.result == -3 && receiver.result == -3 && sender.attempts == 5);
    sender.wrong = 0;
    run(&sender, &receiver);
    assert(sender.result == 1 && receiver.result == 1 && sender.fresh && receiver.fresh);
    receiver.allowed = 0;
    run(&sender, &receiver);
    assert(sender.result != 1 && receiver.result == -1);
    puts("LAN handshake tests passed");
}
