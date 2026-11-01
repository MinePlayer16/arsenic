//
//  DarkSwordServer.m
//  Arsenic
//

#import "DarkSwordServer.h"
#import "../DarkSwordIPC.h"
#import "../kexploit/krw.h"
#import "../kexploit/kexploit_opa334.h"
#import "../kexploit/kutils.h"

#import <Foundation/Foundation.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <pthread.h>
#import <unistd.h>
#import <errno.h>
#import <netinet/in.h>
#include <netinet/tcp.h>
#import <arpa/inet.h>
#include <dlfcn.h>

#define MAX_IPC_BUFFER_SIZE (1024 * 1024)

static volatile BOOL g_server_running = NO;
static int g_server_fd = -1;
static pthread_t g_server_thread = NULL;

static bool safe_recv(int fd, void *buf, size_t len) {
    size_t total_received = 0;
    uint8_t *ptr = (uint8_t *)buf;
    while (total_received < len) {
        ssize_t n = recv(fd, ptr + total_received, len - total_received, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) {
            // Clean EOF / client disconnected
            return false;
        }
        total_received += (size_t)n;
    }
    return true;
}

static bool safe_send(int fd, const void *buf, size_t len) {
    size_t total_sent = 0;
    const uint8_t *ptr = (const uint8_t *)buf;
    while (total_sent < len) {
        ssize_t n = send(fd, ptr + total_sent, len - total_sent, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) {
            return false;
        }
        total_sent += (size_t)n;
    }
    return true;
}

extern char *sandbox_extension_issue_file_to_process_by_pid(const char *extension_class, const char *path, uint32_t flags, pid_t);

BOOL is_darksword_server_running(void) {
    return g_server_running;
}

static pthread_mutex_t g_server_lock = PTHREAD_MUTEX_INITIALIZER;

static void *server_worker(void *arg) {
    int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        printf("[DarkSwordServer] Failed to create TCP socket: %s\n", strerror(errno));
        g_server_running = NO;
        return NULL;
    }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(DARK_SWORD_TCP_PORT);
    addr.sin_addr.s_addr = inet_addr(DARK_SWORD_TCP_ADDR);

    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        printf("[DarkSwordServer] Failed to bind to %s:%d: %s\n", 
               DARK_SWORD_TCP_ADDR, DARK_SWORD_TCP_PORT, strerror(errno));
        close(server_fd);
        g_server_running = NO;
        return NULL;
    }

    if (listen(server_fd, 16) < 0) {
        printf("[DarkSwordServer] Listen failed: %s\n", strerror(errno));
        close(server_fd);
        g_server_running = NO;
        return NULL;
    }

    g_server_fd = server_fd;
    g_server_running = YES;
    printf("[DarkSwordServer] Listening on %s:%d\n", DARK_SWORD_TCP_ADDR, DARK_SWORD_TCP_PORT);

   while (g_server_running) {
        int client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) {
            if (!g_server_running) break;
            continue;
        }

        // Prevents Arsenic from crashing if the client disconnects
        int opt = 1;
        setsockopt(client_fd, SOL_SOCKET, SO_NOSIGPIPE, &opt, sizeof(opt));

        ds_ipc_request_t req;
        while (safe_recv(client_fd, &req, sizeof(req))) {
            ds_ipc_response_t resp = { .status = 0, .data = 0 };
            
            switch (req.op) {
                case OP_PING:
                    resp.data = 0x41414141;
                    break;
                case OP_ISSUE_EXTENSION: {
                    pid_t target_pid = (pid_t)req.value;
                    
                    // Arsenic requests a token for the client's app's PID
                    char *token = sandbox_extension_issue_file_to_process_by_pid("com.apple.app-sandbox.read-write", "/", 0, target_pid);
                    
                    if (token) {
                        uint32_t token_len = (uint32_t)strlen(token) + 1;
                        resp.data = token_len;
                        
                        // sends length and the string itself
                        safe_send(client_fd, &resp, sizeof(resp));
                        safe_send(client_fd, token, token_len);
                        
                        // cleans up token memory
                        void *h = dlopen("libsandbox.dylib", RTLD_NOW);
                        if (!h) h = dlopen("/usr/lib/libsandbox.dylib", RTLD_NOW);
                        void (*sfree)(char *) = h ? dlsym(h, "sandbox_extension_free") : NULL;
                        if (sfree) sfree(token); else free(token);
                    } else {
                        resp.status = (uint32_t)-1;
                        safe_send(client_fd, &resp, sizeof(resp));
                    }
                    continue;
                }
                default:
                    resp.status = (uint32_t)-1;
                    break;
            }

            safe_send(client_fd, &resp, sizeof(resp));
        }

    disconnect_client:
        close(client_fd);
    }

    if (g_server_fd >= 0) {
        close(g_server_fd);
        g_server_fd = -1;
    }
    return NULL;
}

void start_darksword_server(void) {
    if (g_server_running) {
        printf("[DarkSwordServer] Server already running.\n");
        return;
    }

    g_server_running = YES;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);

    int err = pthread_create(&g_server_thread, &attr, server_worker, NULL);
    pthread_attr_destroy(&attr);

    if (err != 0) {
        printf("[DarkSwordServer] pthread_create failed: %d\n", err);
        g_server_running = NO;
    }
}

void stop_darksword_server(void) {
    if (!g_server_running) return;

    g_server_running = NO;
    if (g_server_fd >= 0) {
        shutdown(g_server_fd, SHUT_RDWR);
        close(g_server_fd);
        g_server_fd = -1;
    }
}
