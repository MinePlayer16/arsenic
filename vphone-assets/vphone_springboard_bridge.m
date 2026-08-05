// vphone-only SpringBoard bridge for ArsenicVPhone.
//
// This dylib is copied out of Arsenic.app by vphoned and injected into
// SpringBoard through TweakLoader.  Keep it entitlement-free and do not link it
// into the app target.

#import <CoreFoundation/CoreFoundation.h>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <sandbox.h>
#import <stdbool.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

#if __has_include(<ptrauth.h>)
#import <ptrauth.h>
#endif

#define CY_BRIDGE_MAGIC 0x43595342u
#define CY_BRIDGE_SOCK "/private/var/mobile/Library/Caches/com.iggy05.arsenic.vphone-springboard.sock"
#define CY_BRIDGE_LOG  "/private/var/mobile/Library/Caches/com.iggy05.arsenic.vphone-springboard.log"

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t op;
    uint64_t addr;
    uint64_t size;
    uint64_t args[8];
    char name[128];
} CYBridgeRequest;

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t status;
    uint64_t result;
    uint64_t extra;
} CYBridgeResponse;

static pthread_once_t gLogOnce = PTHREAD_ONCE_INIT;
static FILE *gLog = NULL;

static void cy_log_open(void)
{
    gLog = fopen(CY_BRIDGE_LOG, "a");
}

static void cy_log(const char *fmt, ...)
{
    pthread_once(&gLogOnce, cy_log_open);
    if (!gLog) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(gLog, fmt, ap);
    va_end(ap);
    fputc('\n', gLog);
    fflush(gLog);
}

static bool cy_read_full(int fd, void *buf, size_t len)
{
    uint8_t *p = (uint8_t *)buf;
    while (len) {
        ssize_t n = read(fd, p, len);
        if (n == 0) return false;
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        p += (size_t)n;
        len -= (size_t)n;
    }
    return true;
}

static bool cy_write_full(int fd, const void *buf, size_t len)
{
    const uint8_t *p = (const uint8_t *)buf;
    while (len) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        if (n == 0) return false;
        p += (size_t)n;
        len -= (size_t)n;
    }
    return true;
}

static uint64_t cy_call8(uint64_t addr, const uint64_t args[8])
{
    if (!addr) return 0;
    void *fn = (void *)addr;
#if __has_feature(ptrauth_calls)
    fn = ptrauth_sign_unauthenticated(fn, ptrauth_key_function_pointer, 0);
#endif
    return ((uint64_t (*)(uint64_t, uint64_t, uint64_t, uint64_t,
                         uint64_t, uint64_t, uint64_t, uint64_t))fn)(
        args[0], args[1], args[2], args[3],
        args[4], args[5], args[6], args[7]);
}

static bool cy_is_unsafe_addr_call_name(const char *name)
{
    if (!name || !name[0]) return false;

    // These are not plain C leaf calls in arm64e SpringBoard. Routing them
    // through the generic function-pointer path has produced PAC failures and
    // crash-looped SpringBoard on vphone/iOS 26.x. Keep them blocked unless a
    // dedicated bridge builtin handles the call shape safely.
    static const char *blocked[] = {
        "IOServiceMatching",
        "IOServiceGetMatchingService",
        "IORegistryEntryCreateCFProperty",
        "IOObjectRelease",
        "SBWorkspaceKillApplication",
    };
    for (size_t i = 0; i < sizeof(blocked) / sizeof(blocked[0]); i++) {
        if (strcmp(name, blocked[i]) == 0) return true;
    }
    return false;
}

static uint64_t cy_objc_msgSend(const uint64_t args[8])
{
    if (!args[0] || !args[1]) return 0;

    id target = (id)(uintptr_t)args[0];
    SEL sel = (SEL)(uintptr_t)args[1];
    if (!target || !sel) return 0;

    @try {
        return ((uint64_t (*)(id, SEL, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t))objc_msgSend)(target, sel, args[2], args[3], args[4], args[5], args[6], args[7]);
    } @catch (NSException *ex) {
        cy_log("THREW %s %s 0x%llx",
               sel_getName(sel) ?: "?", ex.name.UTF8String ?: "?",
               (unsigned long long)args[0]);
        return 0;
    }
}

static uint64_t cy_objc_msgSend_main(const uint64_t args[8])
{
    __block uint64_t ret = 0;
    void (^work)(void) = ^{
        ret = cy_objc_msgSend(args);
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return ret;
}

static uint64_t cy_objc_msgSend_main_retain(const uint64_t args[8])
{
    __block uint64_t ret = 0;
    void (^work)(void) = ^{
        ret = cy_objc_msgSend(args);
        if (ret) {
            id obj = (__bridge id)(void *)ret;
            [obj retain];
        }
    };
    if ([NSThread isMainThread]) {
        work();
    } else {
        dispatch_sync(dispatch_get_main_queue(), work);
    }
    return ret;
}

static uint64_t cy_objc_msgSend_retain(const uint64_t args[8])
{
    uint64_t ret = cy_objc_msgSend(args);
    if (ret) {
        id obj = (__bridge id)(void *)ret;
        [obj retain];
    }
    return ret;
}

static bool cy_launch_application_with_bundle_id(uint64_t remoteCString, uint64_t *out)
{
    if (!remoteCString) return false;
    NSString *bundleID = [NSString stringWithUTF8String:(const char *)remoteCString];
    if (!bundleID.length) return false;

    Class workspaceClass = objc_getClass("SBWorkspace");
    SEL defaultWorkspaceSel = sel_registerName("defaultWorkspace");
    SEL openSel = sel_registerName("openApplicationWithBundleID:");
    if (workspaceClass && [workspaceClass respondsToSelector:defaultWorkspaceSel]) {
        id workspace = ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultWorkspaceSel);
        if (workspace && [workspace respondsToSelector:openSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(workspace, openSel, bundleID);
            if (out) *out = 1;
            return true;
        }
    }

    void *sym = dlsym(RTLD_DEFAULT, "SBSLaunchApplicationWithIdentifier");
    if (sym) {
        uint64_t argv[8] = {(uint64_t)remoteCString, 0, 0, 0, 0, 0, 0, 0};
        uint64_t ret = cy_call8((uint64_t)sym, argv);
        if (out) *out = ret;
        return true;
    }
    return false;
}

static bool cy_builtin(const char *name, const uint64_t args[8], uint64_t *out)
{
    if (!name || !name[0] || !out) return false;

#define CY_RET(expr) do { *out = (uint64_t)(expr); return true; } while (0)
#define CY_RET_INT(expr) do { *out = (uint64_t)(int64_t)(expr); return true; } while (0)

    if (strcmp(name, "getpid") == 0) CY_RET_INT(getpid());
    if (strcmp(name, "pthread_exit") == 0) CY_RET(0);
    if (strcmp(name, "malloc") == 0) CY_RET(malloc((size_t)args[0]));
    if (strcmp(name, "calloc") == 0) CY_RET(calloc((size_t)args[0], (size_t)args[1]));
    if (strcmp(name, "free") == 0) { free((void *)args[0]); CY_RET(0); }
    if (strcmp(name, "realloc") == 0) CY_RET(realloc((void *)args[0], (size_t)args[1]));
    if (strcmp(name, "mmap") == 0) CY_RET(mmap((void *)args[0], (size_t)args[1], (int)args[2], (int)args[3], (int)args[4], (off_t)args[5]));
    if (strcmp(name, "munmap") == 0) CY_RET_INT(munmap((void *)args[0], (size_t)args[1]));
    if (strcmp(name, "memset") == 0) CY_RET(memset((void *)args[0], (int)args[1], (size_t)args[2]));
    if (strcmp(name, "memcpy") == 0) CY_RET(memcpy((void *)args[0], (const void *)args[1], (size_t)args[2]));
    if (strcmp(name, "strdup") == 0) CY_RET(strdup((const char *)args[0]));
    if (strcmp(name, "dlopen") == 0) CY_RET(dlopen((const char *)args[0], (int)args[1]));
    if (strcmp(name, "dlsym") == 0) CY_RET(dlsym((void *)args[0], (const char *)args[1]));
    if (strcmp(name, "dladdr") == 0) CY_RET_INT(dladdr((const void *)args[0], (Dl_info *)args[1]));
    if (strcmp(name, "notify_post") == 0) {
        void *sym = dlsym(RTLD_DEFAULT, "notify_post");
        if (!sym) return false;
        CY_RET_INT(((int (*)(const char *))sym)((const char *)args[0]));
    }
    if (strcmp(name, "CFStringCreateWithCString") == 0) {
        CY_RET(CFStringCreateWithCString((CFAllocatorRef)args[0], (const char *)args[1], (CFStringEncoding)args[2]));
    }
    if (strcmp(name, "CFNumberGetValue") == 0) CY_RET(CFNumberGetValue((CFNumberRef)args[0], (CFNumberType)args[1], (void *)args[2]));
    if (strcmp(name, "CFRelease") == 0) { if (args[0]) CFRelease((CFTypeRef)args[0]); CY_RET(0); }
    if (strcmp(name, "CFRetain") == 0) CY_RET(args[0] ? CFRetain((CFTypeRef)args[0]) : NULL);
    if (strcmp(name, "NSStringFromClass") == 0) CY_RET(NSStringFromClass((Class)args[0]));
    if (strcmp(name, "sel_registerName") == 0) CY_RET(sel_registerName((const char *)args[0]));
    if (strcmp(name, "objc_getClass") == 0) CY_RET(objc_getClass((const char *)args[0]));
    if (strcmp(name, "objc_lookUpClass") == 0) CY_RET(objc_lookUpClass((const char *)args[0]));
    if (strcmp(name, "class_getName") == 0) CY_RET(class_getName((Class)args[0]));
    if (strcmp(name, "class_getSuperclass") == 0) CY_RET(class_getSuperclass((Class)args[0]));
    if (strcmp(name, "class_getInstanceMethod") == 0) CY_RET(class_getInstanceMethod((Class)args[0], (SEL)args[1]));
    if (strcmp(name, "class_getMethodImplementation") == 0) CY_RET(class_getMethodImplementation((Class)args[0], (SEL)args[1]));
    if (strcmp(name, "method_getImplementation") == 0) CY_RET(method_getImplementation((Method)args[0]));
    if (strcmp(name, "method_getTypeEncoding") == 0) CY_RET(method_getTypeEncoding((Method)args[0]));
    if (strcmp(name, "method_setImplementation") == 0) CY_RET(method_setImplementation((Method)args[0], (IMP)args[1]));
    if (strcmp(name, "class_addMethod") == 0) CY_RET(class_addMethod((Class)args[0], (SEL)args[1], (IMP)args[2], (const char *)args[3]));
    if (strcmp(name, "class_getInstanceVariable") == 0) CY_RET(class_getInstanceVariable((Class)args[0], (const char *)args[1]));
    if (strcmp(name, "ivar_getOffset") == 0) CY_RET(ivar_getOffset((Ivar)args[0]));
    if (strcmp(name, "object_getClass") == 0) CY_RET(object_getClass((id)args[0]));
    if (strcmp(name, "object_getClassName") == 0) CY_RET(object_getClassName((id)args[0]));
    if (strcmp(name, "object_setClass") == 0) CY_RET(object_setClass((id)args[0], (Class)args[1]));
    if (strcmp(name, "objc_allocateClassPair") == 0) CY_RET(objc_allocateClassPair((Class)args[0], (const char *)args[1], (size_t)args[2]));
    if (strcmp(name, "objc_registerClassPair") == 0) { objc_registerClassPair((Class)args[0]); CY_RET(0); }
    if (strcmp(name, "objc_getAssociatedObject") == 0) CY_RET(objc_getAssociatedObject((id)args[0], (const void *)args[1]));
    if (strcmp(name, "objc_setAssociatedObject") == 0) { objc_setAssociatedObject((id)args[0], (const void *)args[1], (id)args[2], (objc_AssociationPolicy)args[3]); CY_RET(0); }
    if (strcmp(name, "objc_msgSend") == 0) CY_RET(cy_objc_msgSend(args));
    if (strcmp(name, "objc_msgSend_main") == 0) CY_RET(cy_objc_msgSend_main(args));
    if (strcmp(name, "objc_msgSend_main_retain") == 0) CY_RET(cy_objc_msgSend_main_retain(args));
    if (strcmp(name, "objc_msgSend_retain") == 0) CY_RET(cy_objc_msgSend_retain(args));
    if (strcmp(name, "cy_log") == 0) {
        cy_log("APP: %s", (const char *)args[0]);
        CY_RET(0);
    }
    if (strcmp(name, "SBSLaunchApplicationWithIdentifier") == 0) return cy_launch_application_with_bundle_id(args[0], out);
    if (strcmp(name, "sandbox_extension_issue_file") == 0 ||
        strcmp(name, "sandbox_extension_issue_mach") == 0) {
        void *sym = dlsym(RTLD_DEFAULT, name);
        if (!sym) return false;
        CY_RET(cy_call8((uint64_t)sym, args));
    }

#undef CY_RET
#undef CY_RET_INT
    return false;
}

static void cy_handle_client(int fd)
{
    CYBridgeRequest req = {0};
    CYBridgeResponse resp = {.magic = CY_BRIDGE_MAGIC, .status = 1};
    if (!cy_read_full(fd, &req, sizeof(req)) ||
        req.magic != CY_BRIDGE_MAGIC) {
        cy_write_full(fd, &resp, sizeof(resp));
        return;
    }

    switch (req.op) {
        case 1:
            resp.status = 0;
            resp.result = 1;
            break;
        case 2:
            if (cy_builtin(req.name, req.args, &resp.result)) {
                resp.status = 0;
            } else {
                cy_log("unknown builtin: %s", req.name);
            }
            break;
        case 3:
            if (cy_is_unsafe_addr_call_name(req.name)) {
                cy_log("blocked unsafe addr-call: %s addr=%#llx",
                       req.name, (unsigned long long)req.addr);
            } else if (req.addr) {
                resp.status = 0;
                resp.result = cy_call8(req.addr, req.args);
            }
            break;
        case 4:
            if (req.addr && req.size <= 0x100000) {
                resp.status = 0;
                resp.extra = req.size;
                cy_write_full(fd, &resp, sizeof(resp));
                cy_write_full(fd, (const void *)req.addr, (size_t)req.size);
                return;
            }
            break;
        case 5:
            if (req.addr && req.size <= 0x100000) {
                void *buf = malloc((size_t)req.size);
                if (buf && cy_read_full(fd, buf, (size_t)req.size)) {
                    memcpy((void *)req.addr, buf, (size_t)req.size);
                    resp.status = 0;
                    resp.extra = req.size;
                }
                free(buf);
            }
            break;
        case 7: {
            // sb_collect_subviews: BFS from a single root view.
            // req.name = class name to match
            // req.addr = root view pointer
            // req.args[0] = max results
            const char *className = req.name;
            uint64_t rootPtr = req.addr;
            int cap = (int)req.args[0];
            if (!className[0] || !rootPtr || cap <= 0) { cap = cap > 0 ? cap : 64; }
            if (cap > 256) cap = 256;

            __block uint64_t *results = (uint64_t *)calloc(256, sizeof(uint64_t));
            __block int found = 0;
            if (!results) break;

            void (^work)(void) = ^{
                @autoreleasepool {
                    @try {
                        Class klass = objc_getClass(className);
                        if (!klass) return;
                        id root = (id)(uintptr_t)rootPtr;

                        enum { QMAX = 4096 };
                        id *queue = (id *)calloc(QMAX, sizeof(id));
                        if (!queue) return;
                        int head = 0, tail = 0, visited = 0;
                        queue[tail++] = root;
                        while (head < tail && visited < QMAX) {
                            id v = queue[head++];
                            visited++;
                            if (!v) continue;
                            if ([v isKindOfClass:klass]) {
                                if (found < cap) results[found++] = (uint64_t)v;
                                continue;
                            }
                            NSArray *subs = ((NSArray *(*)(id, SEL))objc_msgSend)(v, sel_registerName("subviews"));
                            if (!subs) continue;
                            NSUInteger cn = subs.count;
                            if (cn > 256) cn = 256;
                            for (NSUInteger i = 0; i < cn && tail < QMAX; i++) {
                                id c = [subs objectAtIndex:i];
                                if (c) queue[tail++] = c;
                            }
                        }
                        free(queue);
                    } @catch (NSException *ex) {
                        cy_log("sb_collect_subviews threw %s", ex.name.UTF8String ?: "?");
                    }
                }
            };
            if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);

            resp.status = 0;
            resp.result = (uint64_t)found;
            resp.extra = (uint64_t)(found * sizeof(uint64_t));
            cy_write_full(fd, &resp, sizeof(resp));
            if (found > 0)
                cy_write_full(fd, results, (size_t)(found * sizeof(uint64_t)));
            free(results);
            return;
        }
        case 6: {
            // sb_collect_views: BFS walk of SpringBoard's window hierarchy.
            // req.name = class name to match (e.g. "SBIconListView")
            // req.args[0] = max results
            // Response: resp.result = count, followed by count uint64_t pointers.
            const char *className = req.name;
            int cap = (int)req.args[0];
            if (!className[0] || cap <= 0 || cap > 256) { cap = cap > 0 ? (cap < 256 ? cap : 256) : 64; }

            enum { VIEWS_MAX = 256 };
            uint64_t *results = (uint64_t *)calloc(VIEWS_MAX, sizeof(uint64_t));
            __block int found = 0;
            if (!results) break;

            void (^work)(void) = ^{
                @autoreleasepool {
                    @try {
                        Class klass = objc_getClass(className);
                        if (!klass) { cy_log("sb_collect_views: class '%s' not found", className); return; }

                        id app = [objc_getClass("UIApplication") performSelector:sel_registerName("sharedApplication")];
                        if (!app) return;
                        NSArray *windows = [app performSelector:sel_registerName("windows")];
                        if (!windows.count) {
                            id kw = [app performSelector:sel_registerName("keyWindow")];
                            if (kw) windows = @[kw];
                        }
                        if (!windows.count) return;

                        enum { QMAX = 4096 };
                        id *queue = (id *)calloc(QMAX, sizeof(id));
                        if (!queue) return;
                        int head = 0, tail = 0, visited = 0;
                        for (id win in windows) {
                            if (tail < QMAX) queue[tail++] = win;
                        }
                        while (head < tail && visited < QMAX) {
                            id v = queue[head++];
                            visited++;
                            if (!v) continue;
                            if ([v isKindOfClass:klass]) {
                                if (found < cap) results[found++] = (uint64_t)v;
                                continue;
                            }
                            NSArray *subs = ((NSArray *(*)(id, SEL))objc_msgSend)(v, sel_registerName("subviews"));
                            if (!subs) continue;
                            NSUInteger cn = subs.count;
                            if (cn > 256) cn = 256;
                            for (NSUInteger i = 0; i < cn && tail < QMAX; i++) {
                                id c = [subs objectAtIndex:i];
                                if (c) queue[tail++] = c;
                            }
                        }
                        free(queue);
                        cy_log("sb_collect_views class=%s found=%d visited=%d", className, found, visited);
                    } @catch (NSException *ex) {
                        cy_log("sb_collect_views threw %s", ex.name.UTF8String ?: "(unknown)");
                    }
                }
            };
            if ([NSThread isMainThread]) work(); else dispatch_sync(dispatch_get_main_queue(), work);

            resp.status = 0;
            resp.result = (uint64_t)found;
            resp.extra = (uint64_t)(found * sizeof(uint64_t));
            cy_write_full(fd, &resp, sizeof(resp));
            if (found > 0)
                cy_write_full(fd, results, (size_t)(found * sizeof(uint64_t)));
            free(results);
            return;
        }
        default:
            break;
    }

    cy_write_full(fd, &resp, sizeof(resp));
}

static void *cy_client_thread(void *arg)
{
    int fd = (int)(intptr_t)arg;
    cy_handle_client(fd);
    close(fd);
    return NULL;
}

static void *cy_bridge_thread(void *arg)
{
    (void)arg;
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        cy_log("socket failed errno=%d", errno);
        return NULL;
    }

    struct sockaddr_un sun;
    memset(&sun, 0, sizeof(sun));
    sun.sun_family = AF_UNIX;
    strlcpy(sun.sun_path, CY_BRIDGE_SOCK, sizeof(sun.sun_path));

    unlink(CY_BRIDGE_SOCK);
    if (bind(fd, (struct sockaddr *)&sun, sizeof(sun)) != 0) {
        cy_log("bind failed errno=%d", errno);
        close(fd);
        return NULL;
    }
    chmod(CY_BRIDGE_SOCK, 0666);
    listen(fd, 16);
    cy_log("listening at %s pid=%d", CY_BRIDGE_SOCK, getpid());

    for (;;) {
        int client = accept(fd, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) continue;
            cy_log("accept failed errno=%d", errno);
            continue;
        }
        pthread_t t;
        if (pthread_create(&t, NULL, cy_client_thread, (void *)(intptr_t)client) == 0) {
            pthread_detach(t);
        } else {
            cy_handle_client(client);
            close(client);
        }
    }
}

__attribute__((constructor))
static void cy_bridge_init(void)
{
    pthread_t t;
    if (pthread_create(&t, NULL, cy_bridge_thread, NULL) == 0) {
        pthread_detach(t);
    }
}
